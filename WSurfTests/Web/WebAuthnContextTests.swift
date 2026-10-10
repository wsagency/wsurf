// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@Suite(.boundedWebViews)
@MainActor
struct WebAuthnContextTests {
    private func validate(_ rpID: String?, at origin: String) throws -> String {
        try RelyingPartyPolicy.validate(rpID: rpID, origin: URL(string: origin)!)
    }

    @Test func relyingPartyMustBeTheOriginHostOrItsParent() throws {
        #expect(try validate("login.example.com", at: "https://login.example.com") == "login.example.com")
        #expect(try validate("example.com", at: "https://login.example.com") == "example.com")
        #expect(throws: (any Error).self) {
            try validate("attacker.example", at: "https://login.example.com")
        }
    }

    @Test func intermediateRegistrableParentIsAllowedButSiblingsRemainInvalid() throws {
        #expect(
            try validate("accounts.example.com", at: "https://login.accounts.example.com") ==
                "accounts.example.com"
        )
        #expect(try validate("example.com", at: "https://login.accounts.example.com") == "example.com")
        #expect(throws: (any Error).self) {
            try validate("other.example.com", at: "https://login.accounts.example.com")
        }
        #expect(throws: (any Error).self) {
            try validate("com", at: "https://login.accounts.example.com")
        }
    }

    @Test func publicSuffixRulesRejectExactWildcardAndPrivateSuffixes() throws {
        #expect(throws: (any Error).self) {
            try validate("com", at: "https://login.example.com")
        }
        #expect(throws: (any Error).self) {
            try validate("foo.ck", at: "https://login.foo.ck")
        }
        #expect(try validate("www.ck", at: "https://login.www.ck") == "www.ck")
        #expect(throws: (any Error).self) {
            try validate("github.io", at: "https://alice.github.io")
        }
        #expect(try validate("alice.github.io", at: "https://alice.github.io") == "alice.github.io")
    }

    @Test func idnaAndNondefaultPortUseCanonicalDomainForm() throws {
        #expect(try validate("bücher.de", at: "https://login.bücher.de:8443/path") == "xn--bcher-kva.de")
        #expect(try validate(nil, at: "https://login.bücher.de:8443/path") == "login.xn--bcher-kva.de")
    }

    @Test func secureLocalhostIsAllowedButLoopbackIPIsNotAnRPID() throws {
        #expect(try validate("localhost", at: "http://localhost:8765/login") == "localhost")
        #expect(throws: (any Error).self) {
            try validate("127.0.0.1", at: "https://127.0.0.1:8765")
        }
        #expect(throws: (any Error).self) {
            try validate("localhost", at: "https://example.com")
        }
    }

    @Test func insecureOpaqueAndMalformedRelyingPartyInputsAreRejected() {
        for origin in ["http://example.com", "data:text/html,hello", "file:///tmp/page.html"] {
            #expect(throws: (any Error).self) {
                try RelyingPartyPolicy.validate(rpID: nil, origin: URL(string: origin)!)
            }
        }
        for rpID in ["https://example.com", "example.com:8443", "example.com/login", "*.example.com", "127.0.0.1"] {
            #expect(throws: (any Error).self) {
                try validate(rpID, at: "https://login.example.com")
            }
        }
    }

    @Test func trailingDotDomainIsNotSilentlyStripped() throws {
        #expect(try validate("example.com.", at: "https://login.example.com.") == "example.com.")
        #expect(throws: (any Error).self) {
            try validate("example.com.", at: "https://login.example.com")
        }
    }

    @MainActor
    private final class RegistryLifecycleNavigationDelegate: NSObject, WKNavigationDelegate {
        let page: BrowserPage

        init(page: BrowserPage) {
            self.page = page
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            PageFrameRegistry.shared.navigationStarted(navigation, in: page)
            page.onNavigationStarted?(page.navigation(for: navigation), webView.url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            PageFrameRegistry.shared.navigationCommitted(navigation, in: page)
            page.onNavigationCommitted?(page.navigation(for: navigation))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            page.onNavigationFinished?(page.navigation(for: navigation))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            PageFrameRegistry.shared.navigationFailed(navigation, in: page)
            page.onNavigationFailed?(page.navigation(for: navigation), error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            PageFrameRegistry.shared.navigationFailed(navigation, in: page)
            page.onNavigationFailed?(page.navigation(for: navigation), error)
        }
    }

    enum FixtureError: Error {
        case pageDidNotSettle
        case frameUnavailable
    }

    struct Fixture {
        let page: BrowserPage
        let window: NSWindow
        let origin: String
        let server: HTTPFixtureServer
        let tab: BrowserTab?
    }

    @MainActor
    final class HeldRegistryReplies: NSObject, WKScriptMessageHandlerWithReply {
        private weak var controller: WKUserContentController?
        private var resumes: [(WKScriptMessage, @MainActor @Sendable (Any?, String?) -> Void)] = []
        private var replacementAcknowledgement: (WKScriptMessage, @MainActor @Sendable (Any?, String?) -> Void)?
        private(set) var resumeResults: [Any?] = []
        private(set) var resumeEpochs: [Int] = []

        init(controller: WKUserContentController) {
            self.controller = controller
            super.init()
        }

        var heldResumeCount: Int {
            resumes.count
        }
        var hasHeldReplacementAcknowledgement: Bool {
            replacementAcknowledgement != nil
        }

        func install() {
            guard let controller else { return }
            let world = PageAutomationGuard.world
            controller.removeScriptMessageHandler(forName: PageFrameRegistry.resumeHandlerName, contentWorld: world)
            controller.removeScriptMessageHandler(forName: PageFrameRegistry.acknowledgementHandlerName, contentWorld: world)
            controller.addScriptMessageHandler(self, contentWorld: world, name: PageFrameRegistry.resumeHandlerName)
            controller.addScriptMessageHandler(self, contentWorld: world, name: PageFrameRegistry.acknowledgementHandlerName)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            if message.name == PageFrameRegistry.resumeHandlerName {
                let epoch = (message.body as? [String: Any])?["epoch"] as? Int ?? -1
                resumes.append((message, replyHandler))
                resumeEpochs.append(epoch)
            } else if message.name == PageFrameRegistry.acknowledgementHandlerName,
                      message.frameInfo.isMainFrame,
                      message.frameInfo.request.url?.path == "/replacement" {
                replacementAcknowledgement = (message, replyHandler)
            } else {
                PageFrameRegistry.shared.userContentController(
                    userContentController, didReceive: message, replyHandler: replyHandler
                )
            }
        }

        func releaseResume(at index: Int = 0) {
            guard let controller, resumes.indices.contains(index) else { return }
            let held = resumes.remove(at: index)
            let epoch = (held.0.body as? [String: Any])?["epoch"] as? Int ?? -1
            PageFrameRegistry.shared.userContentController(
                controller, didReceive: held.0, replyHandler: { [weak self] value, error in
                    self?.resumeResults.append(value)
                    held.1(value, error)
                }
            )
        }

        func releaseReplacementAcknowledgement() {
            guard let controller, let held = replacementAcknowledgement else { return }
            replacementAcknowledgement = nil
            PageFrameRegistry.shared.userContentController(
                controller, didReceive: held.0, replyHandler: held.1
            )
        }
    }

    /// Issues the real registry nonce, then pushes history state before the main-frame reply, so the page's unmodified
    /// registry script sends its acknowledgement from a document whose URL changed after the nonce was issued.
    /// Only the original document ("/") is mutated; later documents such as "/next" reply unchanged, so the push
    /// cannot add a history entry to a second document.
    @MainActor
    final class PushBeforeNonceReply: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            let isOriginalDocument = message.frameInfo.isMainFrame && message.frameInfo.request.url?.path == "/"
            let webView = message.webView
            PageFrameRegistry.shared.userContentController(
                userContentController, didReceive: message, replyHandler: { nonce, error in
                    guard isOriginalDocument, error == nil, nonce is String else {
                        replyHandler(nonce, error)
                        return
                    }
                    guard let webView else {
                        replyHandler(nil, "The fixture web view is unavailable.")
                        return
                    }
                    webView.evaluateJavaScript("history.pushState({early: true}, '', '/#before-registry-ack');") { _, pushError in
                        if let pushError {
                            replyHandler(nil, "The fixture history push failed: \(pushError.localizedDescription)")
                        } else {
                            replyHandler(nonce, nil)
                        }
                    }
                }
            )
        }
    }

    @MainActor
    final class HeldChildLivenessWebView: WKWebView {
        var holdChildLiveness = false
        private var heldCompletion: (@MainActor @Sendable (Any?, (any Error)?) -> Void)?
        private var heldResult: Any?
        private var heldError: (any Error)?
        private(set) var didHoldChildLiveness = false

        override func __callAsyncJavaScript(
            _ functionBody: String,
            arguments: [String: Any]?,
            inFrame frame: WKFrameInfo?,
            in contentWorld: WKContentWorld,
            completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)?
        ) {
            let shouldHold = holdChildLiveness
                && functionBody == "return globalThis.__wsurfNativeFrameNonce === nonce;"
                && frame?.isMainFrame == false
            super.__callAsyncJavaScript(
                functionBody, arguments: arguments, inFrame: frame, in: contentWorld,
                completionHandler: { [weak self] result, error in
                    guard shouldHold, let self, let completionHandler else {
                        completionHandler?(result, error)
                        return
                    }
                    self.holdChildLiveness = false
                    self.heldResult = result
                    self.heldError = error
                    self.heldCompletion = completionHandler
                    self.didHoldChildLiveness = true
                }
            )
        }

        var heldLivenessValue: Any? {
            heldResult
        }

        func releaseHeldChildLiveness() {
            guard let heldCompletion else { return }
            self.heldCompletion = nil
            heldCompletion(heldResult, heldError)
        }
    }

    func loadPage(
        engine: BrowserEngine,
        profile: Profile = Profile(id: UUID(), name: "WebAuthn fixture", symbol: "key", color: .blue),
        permissionsPolicy: String? = "publickey-credentials-create=(self), publickey-credentials-get=(self)",
        body: String = "<!doctype html><title>Credential context</title>",
        pushBeforeRegistryAck: Bool = false,
        recordTrustedPageShows: Bool = false,
        pendingNavigation: ResponseGate? = nil
    ) async throws -> Fixture {
        var headers: [String: String] = [:]
        if let permissionsPolicy { headers["Permissions-Policy"] = permissionsPolicy }
        var routes: [String: HTTPFixtureServer.Response] = [
            "/": .html(body, headers: headers),
            "/next": .html("<!doctype html><title>Next</title>", headers: headers),
            "/child-one": .html("<!doctype html><title>Child one</title>"),
            "/child-two": .html("<!doctype html><title>Child two</title>"),
        ]
        if let pendingNavigation {
            routes["/stalled"] = .html("<!doctype html><title>Stalled</title>", headers: headers, gate: pendingNavigation)
        }
        let server = try await HTTPFixtureServer.start(routes: routes)
        var components = try #require(URLComponents(url: try server.url(), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let url = try #require(components.url)
        let context = BrowserProfileContext(profile: profile)
        let page: BrowserPage
        let tab: BrowserTab?
        switch engine {
        case .webKit:
            let configuration: WKWebViewConfiguration
            if pushBeforeRegistryAck {
                configuration = WebViewPool.makeConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let controller = configuration.userContentController
                controller.addUserScript(WKUserScript(
                    source: """
                    globalThis.__wsurfPersistedForTest = false;
                    addEventListener('pageshow', event => {
                        if (event.persisted) globalThis.__wsurfPersistedForTest = true;
                    });
                    """,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                ))
                let world = PageAutomationGuard.world
                controller.removeScriptMessageHandler(forName: PageFrameRegistry.handlerName, contentWorld: world)
                controller.addScriptMessageHandler(PushBeforeNonceReply(), contentWorld: world, name: PageFrameRegistry.handlerName)
            } else {
                configuration = fixtureWebKitConfiguration(recordTrustedPageShows: recordTrustedPageShows)
                configuration.websiteDataStore = .nonPersistent()
            }
            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 500, height: 400),
                configuration: configuration
            )
            let browserTab = BrowserTab(
                adopting: webView,
                opensBlank: false,
                privately: profile.isPrivate,
                context: context
            )
            page = browserTab.page
            tab = browserTab
        case .chromium:
            page = BrowserPage(chromium: ChromiumPage(context: context))
            tab = nil
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        page.load(URLRequest(url: url))
        guard await PageSettle.untilIdle(page, timeout: .seconds(30)) else {
            await page.close()
            window.close()
            throw FixtureError.pageDidNotSettle
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return Fixture(page: page, window: window, origin: "\(url.scheme!)://\(url.host!)\(port)", server: server, tab: tab)
    }

    func fixtureWebKitConfiguration(recordTrustedPageShows: Bool = false) -> WKWebViewConfiguration {
        let configuration = WebViewPool.makeConfiguration()
        if recordTrustedPageShows {
            configuration.userContentController.addUserScript(WKUserScript(
                source: """
                globalThis.__wsurfPageShowsForTest = [];
                addEventListener('pageshow', event => {
                  globalThis.__wsurfPageShowsForTest.push({
                    trusted: event.isTrusted,
                    path: location.pathname,
                    fragment: location.hash,
                    persisted: event.persisted
                  });
                });
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        return configuration
    }

    func host(_ page: BrowserPage) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        return window
    }

    func withPage(
        _ page: BrowserPage,
        window: NSWindow,
        tab: BrowserTab? = nil,
        cleanup: () -> Void = {},
        body: () async throws -> Void
    ) async throws {
        func finish() async {
            cleanup()
            if let tab {
                let profile = tab.context.profile
                tab.detach()
                await tab.waitForRetirement()
                await Profile.erase(profile)
            } else {
                await page.close()
            }
            window.contentView = nil
            window.close()
        }
        do {
            try await body()
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    func ownedWebKitTab(_ webView: WKWebView) -> BrowserTab {
        BrowserTab(
            adopting: webView,
            opensBlank: false,
            privately: false,
            context: BrowserProfileContext(profile: Profile(
                id: UUID(), name: "WebAuthn fixture", symbol: "key", color: .blue
            ))
        )
    }

    func localURL(_ server: HTTPFixtureServer, path: String) throws -> URL {
        var components = try #require(URLComponents(url: try server.url(path), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        return try #require(components.url)
    }
    func withFixture(_ fixture: Fixture, body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await fixture.page.close()
            fixture.window.close()
            throw error
        }
        await fixture.page.close()
        fixture.window.close()
    }

    func mainFrame(in page: BrowserPage) async throws -> BrowserFrame {
        if page.engine == .webKit {
            guard await waitUntil({ PageFrameRegistry.shared.mainFrame(in: page) != nil }),
                  let frame = PageFrameRegistry.shared.mainFrame(in: page) else {
                throw FixtureError.frameUnavailable
            }
            return frame
        }
        guard let frame = try await page.chromium?.frames().first(where: \.isMainFrame) else {
            throw FixtureError.frameUnavailable
        }
        return frame
    }

    @Test(arguments: BrowserEngine.allCases)
    func mainFrameContextUsesNativeOriginAndCurrentProfile(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(engine: engine)
        try await withFixture(fixture) {
            let frame = try await mainFrame(in: fixture.page)
            let context = try await fixture.page.credentialContext(for: frame, operation: .get)
            #expect(context.profileID == fixture.page.profileID)
            #expect(!context.isPrivate)
            #expect(context.origin == fixture.origin)
            #expect(context.topOrigin == nil)
            #expect(!context.crossOrigin)
            #expect(context.operation == .get)
            try await context.validate()
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func permissionsPolicyDenialAndPrivateProfileRefuseContexts(_ engine: BrowserEngine) async throws {
        let denied = try await loadPage(engine: engine, permissionsPolicy: "publickey-credentials-get=()")
        try await withFixture(denied) {
            let frame = try await mainFrame(in: denied.page)
            var refused = false
            do {
                _ = try await denied.page.credentialContext(for: frame, operation: .get)
            } catch WebAuthnContextError.policyDenied {
                refused = true
            }
            #expect(refused)
        }

        let privateFixture = try await loadPage(engine: engine, profile: .privateBrowsing())
        try await withFixture(privateFixture) {
            let frame = try await mainFrame(in: privateFixture.page)
            var refused = false
            do {
                _ = try await privateFixture.page.credentialContext(for: frame, operation: .get)
            } catch WebAuthnContextError.privateProfile {
                refused = true
            }
            #expect(refused)
        }
    }

    @Test
    func escapedUnknownDirectiveCannotHideCredentialPolicyDenial() async throws {
        let policy = #"x=("\""), publickey-credentials-get=()"#
        let fixture = try await loadPage(engine: .webKit, permissionsPolicy: policy)
        try await withFixture(fixture) {
            let frame = try await mainFrame(in: fixture.page)
            var denied = false
            do {
                _ = try await fixture.page.credentialContext(for: frame, operation: .get)
            } catch WebAuthnContextError.policyDenied {
                denied = true
            } catch {}
            #expect(denied)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func defaultSelfPolicyAllowsMainFrameButPrivateProfilesCannotCreateContext(_ engine: BrowserEngine) async throws {
        let missingPolicy = try await loadPage(engine: engine, permissionsPolicy: nil)
        try await withFixture(missingPolicy) {
            let frame = try await mainFrame(in: missingPolicy.page)
            let context = try await missingPolicy.page.credentialContext(for: frame, operation: .get)
            try await context.validate()
        }

        let absentDirective = try await loadPage(engine: engine, permissionsPolicy: "camera=()")
        try await withFixture(absentDirective) {
            let frame = try await mainFrame(in: absentDirective.page)
            let context = try await absentDirective.page.credentialContext(for: frame, operation: .create)
            try await context.validate()
        }

        let privatePage = try await loadPage(engine: engine, profile: .privateBrowsing())
        try await withFixture(privatePage) {
            let frame = try await mainFrame(in: privatePage.page)
            await #expect(throws: (any Error).self) {
                try await privatePage.page.credentialContext(for: frame, operation: .get)
            }
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func bareWildcardPermissionsPolicyAllowsTheRequestedFeature(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(engine: engine, permissionsPolicy: "publickey-credentials-get=*")
        try await withFixture(fixture) {
            let frame = try await mainFrame(in: fixture.page)
            let context = try await fixture.page.credentialContext(for: frame, operation: .get)
            try await context.validate()
        }
    }

    @Test
    func unassociatedWebKitResponseCannotAuthorizeDefaultSelfPolicy() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Unassociated</title>")
        ])
        var components = try #require(URLComponents(url: try server.url(), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let page = BrowserPage(webKit: webView, context: BrowserProfileContext(profile: Profile(
            id: UUID(), name: "Unassociated fixture", symbol: "key", color: .blue
        )))
        let delegate = RegistryLifecycleNavigationDelegate(page: page)
        webView.navigationDelegate = delegate
        let window = host(page)
        try await withPage(page, window: window, cleanup: { withExtendedLifetime(delegate) {} }) {
            page.load(URLRequest(url: try #require(components.url)))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let frame = try await mainFrame(in: page)
            var unavailable = false
            do {
                _ = try await page.credentialContext(for: frame, operation: .get)
            } catch WebAuthnContextError.policyUnavailable {
                unavailable = true
            } catch {}
            #expect(unavailable)
        }
    }
    @Test
    func nonHTTPSMainFrameKeepsHTTPChildButCannotAuthorizeCredentials() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/child": .html("<!doctype html><title>HTTP child</title>")
        ])
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-frame-registry-\(UUID().uuidString).html")
        try Data("""
        <!doctype html><title>Local main</title>
        <iframe src="\(try server.url("/child").absoluteString)"></iframe>
        """.utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let configuration = fixtureWebKitConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = ownedWebKitTab(webView)
        let page = tab.page
        let window = host(page)
        try await withPage(page, window: window, tab: tab) {
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let main = try await mainFrame(in: page)
            #expect(main.request.url?.isFileURL == true)
            #expect(!main.hasTrustedSecurityOrigin)
            try #require(await waitUntil {
                await PageFrameRegistry.shared.targets(in: page).contains { $0.url.path == "/child" }
            })
            var refused = false
            do {
                _ = try await page.credentialContext(for: main, operation: .get)
            } catch WebAuthnContextError.staleFrame {
                refused = true
            } catch {}
            #expect(refused)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func navigationInvalidatesPreviouslyCapturedContext(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(engine: engine)
        try await withFixture(fixture) {
            let frame = try await mainFrame(in: fixture.page)
            let context = try await fixture.page.credentialContext(for: frame, operation: .get)
            fixture.page.load(URLRequest(url: try fixture.server.url("/next")))
            #expect(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            var stale = false
            do {
                try await context.validate()
            } catch WebAuthnContextError.staleFrame {
                stale = true
            }
            #expect(stale)
        }
    }

    @Test
    func webContentProcessTerminationInvalidatesBindingAndCancelsPendingRequestWithoutReload() async throws {
        let pendingNavigation = ResponseGate()
        defer { pendingNavigation.open() }
        let fixture = try await loadPage(engine: .webKit, pendingNavigation: pendingNavigation)
        try await withFixture(fixture) {
            let tab = try #require(fixture.tab)
            let page = fixture.page
            let webView = try #require(page.webKit)
            let delegate = try #require(webView.navigationDelegate as? TabNavigationDelegate)
            #expect(delegate === tab.navigationDelegate)
            page.context.settings.passwordProvider = .credentialManager
            let routeScript = """
            (() => { let route = null; const note = event => { route = event.detail; };
              document.addEventListener('wsurf-webauthn-route', note);
              document.dispatchEvent(new CustomEvent('wsurf-webauthn-route-request'));
              document.removeEventListener('wsurf-webauthn-route', note); return route; })()
            """
            try #require(await waitUntil {
                (try? await page.evaluateJavaScript(routeScript)) as? String == "manager"
            })

            let originalFrame = try await mainFrame(in: page)
            let originalContext = try await page.credentialContext(for: originalFrame, operation: .get)
            try await originalContext.validate()
            _ = try await page.evaluateJavaScript("""
            const field = document.createElement('input');
            field.setAttribute('autocomplete', 'username webauthn');
            document.body.append(field);
            globalThis.__terminationRequestPosted = false;
            globalThis.__terminationRequestOutcome = 'pending';
            document.addEventListener('wsurf-webauthn-request', event => {
              try {
                const request = JSON.parse(event.detail);
                if (request.action === 'request' && request.operation === 'get')
                  globalThis.__terminationRequestPosted = true;
              } catch {}
            });
            navigator.credentials.get({
              mediation: 'conditional',
              publicKey: { challenge: new Uint8Array([1, 2, 3, 4]) }
            }).then(
              () => globalThis.__terminationRequestOutcome = 'resolved',
              error => globalThis.__terminationRequestOutcome = error.name
            );
            true
            """)
            try #require(await waitUntil {
                let posted = (try? await page.evaluateJavaScript("globalThis.__terminationRequestPosted") as? Bool) == true
                let outcome = try? await page.evaluateJavaScript("globalThis.__terminationRequestOutcome") as? String
                return posted && outcome == "pending"
            })

            #expect(tab.processState.shouldReloadAfterUnexpectedTermination(at: .distantFuture))
            delegate.webViewWebContentProcessDidTerminate(webView)
            #expect(!page.isLoading)
            #expect(page.url?.path == "/")
            #expect(page.credentialGeneration > originalContext.credentialGeneration)
            #expect(throws: (any Error).self) {
                try originalContext.validateForDispatch()
            }
            #expect(PageFrameRegistry.shared.mainFrame(in: page) == nil)
            try #require(await waitUntil {
                (try? await page.evaluateJavaScript("globalThis.__terminationRequestOutcome") as? String)
                    == "NotAllowedError"
            })

            page.load(URLRequest(url: try localURL(fixture.server, path: "/next")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let recoveredFrame = try await mainFrame(in: page)
            let recoveredContext = try await page.credentialContext(for: recoveredFrame, operation: .get)
            try await recoveredContext.validate()

            page.load(URLRequest(url: try localURL(fixture.server, path: "/stalled")))
            try #require(await pendingNavigation.waitForRequest())
            #expect(PageFrameRegistry.shared.mainFrame(in: page)?.documentID == recoveredFrame.documentID)
            #expect(tab.processState.shouldReloadAfterUnexpectedTermination(at: .distantFuture))
            delegate.webViewWebContentProcessDidTerminate(webView)
            #expect(PageFrameRegistry.shared.mainFrame(in: page) == nil)

            page.load(URLRequest(url: try localURL(fixture.server, path: "/next")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let finalFrame = try await mainFrame(in: page)
            let finalContext = try await page.credentialContext(for: finalFrame, operation: .get)
            try await finalContext.validate()
            pendingNavigation.open()
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            #expect(PageFrameRegistry.shared.mainFrame(in: page)?.documentID == finalFrame.documentID)
            try await finalContext.validate()
        }
    }

}
