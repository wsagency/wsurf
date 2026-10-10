// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import AppKit
import WebKit

@testable import WSurf

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
    private enum FixtureError: Error {
        case pageDidNotSettle
        case frameUnavailable
    }
    @MainActor
    private struct PageFixture {
        let page: BrowserPage
        let window: NSWindow
        let origin: String
        let server: HTTPFixtureServer
        let tab: BrowserTab?
    }

    @MainActor
    private func withPage(
        _ page: BrowserPage,
        window: NSWindow? = nil,
        cleanup: @MainActor () -> Void = {},
        body: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            cleanup()
            await page.close()
            window?.close()
            throw error
        }
        cleanup()
        await page.close()
        window?.close()
    }

    @MainActor
    private func withFixture(
        _ fixture: PageFixture,
        body: @MainActor (PageFixture) async throws -> Void
    ) async throws {
        try await withPage(fixture.page, window: fixture.window) {
            try await body(fixture)
        }
    }

    @MainActor
    private final class HeldRegistryReplies: NSObject, WKScriptMessageHandlerWithReply {
        private weak var controller: WKUserContentController?
        private var resumes: [(WKScriptMessage, @MainActor @Sendable (Any?, String?) -> Void)] = []
        private var replacementAcknowledgement: (WKScriptMessage, @MainActor @Sendable (Any?, String?) -> Void)?
        private(set) var resumeResult: Any?
        private(set) var resumeResults: [Any?] = []
        private(set) var resumeEpochs: [Int] = []
        private(set) var didCompleteResume = false

        init(controller: WKUserContentController) {
            self.controller = controller
            super.init()
        }

        var hasHeldResume: Bool { !resumes.isEmpty }
        var heldResumeCount: Int { resumes.count }
        var hasHeldReplacementAcknowledgement: Bool { replacementAcknowledgement != nil }

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
                resumes.append((message, replyHandler))
                resumeEpochs.append((message.body as? [String: Any])?["epoch"] as? Int ?? -1)
                return
            }
            if message.name == PageFrameRegistry.acknowledgementHandlerName,
               message.frameInfo.isMainFrame,
               message.frameInfo.request.url?.path == "/replacement" {
                replacementAcknowledgement = (message, replyHandler)
                return
            }
            PageFrameRegistry.shared.userContentController(
                userContentController, didReceive: message, replyHandler: replyHandler
            )
        }

        func releaseResume(at index: Int = 0) {
            guard let controller, resumes.indices.contains(index) else { return }
            let held = resumes.remove(at: index)
            let epoch = (held.0.body as? [String: Any])?["epoch"] as? Int ?? -1
            print("[TEMP heldResume] release epoch=\(epoch) pending=\(resumes.count)")
            PageFrameRegistry.shared.userContentController(
                controller, didReceive: held.0, replyHandler: { [weak self] value, error in
                    self?.resumeResult = value
                    self?.resumeResults.append(value)
                    self?.didCompleteResume = true
                    held.1(value, error)
                    print("[TEMP heldResume] complete epoch=\(epoch) result=\(String(describing: value)) error=\(String(describing: error)) pending=\(self?.resumes.count ?? -1)")
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

    @MainActor
    private final class HeldChildLivenessWebView: WKWebView {
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

        var heldLivenessValue: Any? { heldResult }

        func releaseHeldChildLiveness() {
            guard let heldCompletion else { return }
            self.heldCompletion = nil
            heldCompletion(heldResult, heldError)
        }
    }

    @MainActor
    private func loadPage(
        engine: BrowserEngine,
        profile: Profile = .original(),
        permissionsPolicy: String? = "publickey-credentials-create=(self), publickey-credentials-get=(self)",
        body: String = "<!doctype html><title>Credential context</title>"
    ) async throws -> PageFixture {
        var headers: [String: String] = [:]
        if let permissionsPolicy {
            headers["Permissions-Policy"] = permissionsPolicy
        }
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html(body, headers: headers),
            "/next": .html("<!doctype html><title>Next</title>", headers: headers),
            "/child-one": .html("<!doctype html><title>Child one</title>"),
            "/child-two": .html("<!doctype html><title>Child two</title>"),
        ])
        let base = try server.url()
        var components = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let url = try #require(components.url)

        let page: BrowserPage
        let tab: BrowserTab?
        switch engine {
        case .webKit:
            let configuration = WebViewPool.makeConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 500, height: 400),
                configuration: configuration
            )
            let browserTab = BrowserTab(adopting: webView, opensBlank: false, privately: profile.isPrivate)
            page = browserTab.page
            tab = browserTab
        case .chromium:
            page = BrowserPage(chromium: ChromiumPage(profile: profile))
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
        guard let scheme = url.scheme, let host = url.host else {
            await page.close()
            window.close()
            throw FixtureError.frameUnavailable
        }
        let originPort = url.port.map { ":\($0)" } ?? ""
        return PageFixture(
            page: page, window: window, origin: "\(scheme)://\(host)\(originPort)", server: server, tab: tab
        )
    }

    @MainActor
    private func mainFrame(in page: BrowserPage) async throws -> BrowserFrame {
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

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    @MainActor
    func mainFrameContextUsesNativeOriginPolicyAndProfile(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(engine: engine)
        try await withFixture(fixture) { fixture in
            try await fixture.page.evaluateJavaScript(
                "globalThis.__wsurfOrigin = 'https://attacker.example'; globalThis.__wsurfPolicy = true;"
            )
            let frame = try await mainFrame(in: fixture.page)
            let context = try await fixture.page.credentialContext(for: frame, operation: .get)

            #expect(context.profileID == fixture.page.profileID)
            #expect(context.isPrivate == false)
            #expect(context.origin == fixture.origin)
            #expect(context.topOrigin == nil)
            #expect(context.crossOrigin == false)
            #expect(context.operation == .get)
            try await context.validate()
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    @MainActor
    func defaultSelfPolicyAllowsMainFrameButPrivateProfilesCannotCreateContext(_ engine: BrowserEngine) async throws {
        let missingPolicy = try await loadPage(engine: engine, permissionsPolicy: nil)
        try await withFixture(missingPolicy) { missingPolicy in
            let frame = try await mainFrame(in: missingPolicy.page)
            let context = try await missingPolicy.page.credentialContext(for: frame, operation: .get)
            try await context.validate()
        }

        let absentDirective = try await loadPage(engine: engine, permissionsPolicy: "geolocation=()")
        try await withFixture(absentDirective) { absentDirective in
            let frame = try await mainFrame(in: absentDirective.page)
            let context = try await absentDirective.page.credentialContext(for: frame, operation: .create)
            try await context.validate()
        }

        let privatePage = try await loadPage(engine: engine, profile: .privateBrowsing())
        try await withFixture(privatePage) { privatePage in
            let frame = try await mainFrame(in: privatePage.page)
            await #expect(throws: (any Error).self) {
                try await privatePage.page.credentialContext(for: frame, operation: .get)
            }
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    @MainActor
    func bareWildcardPermissionsPolicyAllowsTheRequestedFeature(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(
            engine: engine,
            permissionsPolicy: "publickey-credentials-get=*"
        )
        try await withFixture(fixture) { fixture in
            let frame = try await mainFrame(in: fixture.page)
            let context = try await fixture.page.credentialContext(for: frame, operation: .get)
            try await context.validate()
        }
    }

    @Test(.boundedWebViews)
    @MainActor
    func unassociatedWebKitResponseCannotAuthorizeDefaultSelfPolicy() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Unassociated</title>")])
        var components = try #require(URLComponents(url: try server.url(), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(webKit: WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        ))
        try await withPage(page) {
            page.load(URLRequest(url: try #require(components.url)))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            guard await waitUntil({ PageFrameRegistry.shared.mainFrame(in: page) != nil }),
                  let frame = PageFrameRegistry.shared.mainFrame(in: page) else {
                throw FixtureError.frameUnavailable
            }
            var unavailable = false
            do {
                _ = try await page.credentialContext(for: frame, operation: .get)
            } catch WebAuthnContextError.policyUnavailable {
                unavailable = true
            } catch {}
            #expect(unavailable)
        }
    }

    @Test(.boundedWebViews)
    @MainActor
    func backForwardRestoreReestablishesMainFramePolicyAndNonce() async throws {
        let fixture = try await loadPage(engine: .webKit)
        try await withFixture(fixture) { fixture in
            let original = try await mainFrame(in: fixture.page)
            let originalNonce = original.documentID
            _ = try await fixture.page.evaluateJavaScript(
                "globalThis.__wsurfPersistedTest = false; addEventListener('pageshow', event => { globalThis.__wsurfPersistedTest = event.persisted; });"
            )
            fixture.page.load(URLRequest(url: try fixture.server.url("/next")))
            #expect(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            fixture.page.goBack()
            #expect(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            guard await waitUntil({ PageFrameRegistry.shared.mainFrame(in: fixture.page) != nil }),
                  let restored = PageFrameRegistry.shared.mainFrame(in: fixture.page) else {
                throw FixtureError.frameUnavailable
            }
            let persisted = try await fixture.page.evaluateJavaScript(
                "globalThis.__wsurfPersistedTest === true"
            ) as? Bool
            if persisted == true {
                #expect(restored.documentID == originalNonce)
            } else {
                #expect(restored.documentID != originalNonce)
            }
            let context = try await fixture.page.credentialContext(for: restored, operation: .get)
            try await context.validate()
        }
    }

    @Test(.boundedWebViews)
    @MainActor
    func historyAPIURLChangesSurviveBackForwardCredentialContextRestore() async throws {
        let fixture = try await loadPage(engine: .webKit)
        try await withFixture(fixture) { fixture in
            let original = try await mainFrame(in: fixture.page)
            _ = try await fixture.page.evaluateJavaScript("""
            globalThis.__restoredPersisted = false;
            addEventListener('pageshow', event => {
              if (event.persisted) globalThis.__restoredPersisted = true;
            });
            history.replaceState({stage: 'replace'}, '', '/replaced');
            history.pushState({stage: 'push'}, '', '/pushed');
            location.hash = 'restored';
            true
            """)

            var nextComponents = try #require(URLComponents(
                url: try fixture.server.url("/next"), resolvingAgainstBaseURL: false
            ))
            nextComponents.host = "localhost"
            fixture.page.load(URLRequest(url: try #require(nextComponents.url)))
            try #require(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            fixture.page.goBack()
            try #require(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            try #require(await waitUntil {
                (try? await fixture.page.evaluateJavaScript("globalThis.__restoredPersisted === true")) as? Bool == true
            })
            #expect(fixture.page.url?.path == "/pushed")
            #expect(fixture.page.url?.fragment == "restored")
            let restored = try await mainFrame(in: fixture.page)
            #expect(restored.documentID == original.documentID)
            let context = try await fixture.page.credentialContext(for: restored, operation: .get)
            try await context.validate()
        }
    }

    @Test(.boundedWebViews)
    @MainActor
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

        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let page = BrowserPage(webKit: webView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        try await withPage(page, window: window) {
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

    @Test(.boundedWebViews)
    @MainActor
    func registryRestoresMainAndHTTPChildWithoutCredentialRelay() async throws {
        let allow = ["Permissions-Policy": "publickey-credentials-get=(self)"]
        let server = try await HTTPFixtureServer.start(routes: [
            "/restore": .html("""
            <!doctype html><title>Restore</title><iframe src="/child"></iframe>
            <script>addEventListener('pageshow', event => { if (event.persisted) globalThis.__restored = true; });</script>
            """, headers: allow),
            "/child": .html("<!doctype html><title>Child</title>"),
            "/other": .html("<!doctype html><title>Other</title>", headers: allow)
        ])
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = BrowserTab(adopting: webView, opensBlank: false, privately: false)
        let page = tab.page
        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        let world = PageAutomationGuard.world
        for name in [
            PageFrameRegistry.handlerName,
            PageFrameRegistry.acknowledgementHandlerName,
            PageFrameRegistry.resumeHandlerName
        ] {
            controller.removeScriptMessageHandler(forName: name, contentWorld: world)
        }
        PageFrameRegistry.install(in: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        try await withPage(page, window: window) {

        var components = try #require(URLComponents(
            url: try server.url("/restore"), resolvingAgainstBaseURL: false
        ))
        components.host = "localhost"
        let restoreURL = try #require(components.url)
        components.path = "/other"
        let otherURL = try #require(components.url)
        page.load(URLRequest(url: restoreURL))
        try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        let original = try await mainFrame(in: page)
        try #require(await waitUntil {
            await PageFrameRegistry.shared.targets(in: page).contains { $0.url.path == "/child" }
        })
        let originalChild = try #require(
            await PageFrameRegistry.shared.targets(in: page).first { $0.url.path == "/child" }
        )

        page.load(URLRequest(url: otherURL))
        try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        page.goBack()
        try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        try #require(await page.evaluateJavaScript("globalThis.__restored === true") as? Bool == true)
        let restored = try await mainFrame(in: page)
        #expect(restored.documentID == original.documentID)
        #expect(PageFrameRegistry.shared.mainFramePolicyAllows(
            restored, feature: "publickey-credentials-get", in: page
        ) == true)
        let proof = try #require(await page.callAsyncJavaScript(
            """
            return {
              nonce: globalThis.__wsurfNativeFrameNonce,
              epoch: globalThis.__wsurfNativeFrameEpoch,
              ready: await globalThis.__wsurfNativeFrameReady
            };
            """,
            in: nil,
            contentWorld: world
        ) as? [String: Any])
        #expect(proof["nonce"] as? String == original.documentID)
        #expect(proof["epoch"] as? Int == 1)
        #expect(proof["ready"] as? Bool == true)

        var candidateChild: PageFrameRegistry.Target?
        try #require(await waitUntil {
            candidateChild = await PageFrameRegistry.shared.targets(in: page).first { $0.id == originalChild.id }
            return candidateChild != nil
        })
        let restoredChild = try #require(candidateChild)
        #expect(restoredChild.frame.documentID == originalChild.frame.documentID)
        #expect(await PageFrameRegistry.shared.isLive(restoredChild, in: page))
        let context = try await page.credentialContext(for: restored, operation: .get)
        try await context.validate()

        PageFrameRegistry.shared.retire(page)
        #expect(PageFrameRegistry.shared.mainFrame(in: page) == nil)
        #expect(await PageFrameRegistry.shared.targets(in: page).isEmpty)
        }
    }

    @Test(.boundedWebViews)
    @MainActor
    func lateNativeChildLivenessResultCannotRestoreAChildIntoANewDocument() async throws {
        let allow = ["Permissions-Policy": "publickey-credentials-get=(self)"]
        let deny = ["Permissions-Policy": "publickey-credentials-get=()"]
        let server = try await HTTPFixtureServer.start(routes: [
            "/restore": .html("""
            <!doctype html><title>Restore</title><iframe src="/child"></iframe>
            <script>addEventListener('pageshow', event => { if (event.persisted) globalThis.__restored = true; });</script>
            """, headers: allow),
            "/child": .html("<!doctype html><title>Original child</title>"),
            "/other": .html("<!doctype html><title>Other</title>", headers: allow),
            "/replacement": .html("<!doctype html><title>Replacement</title><iframe src='/child-two'></iframe>", headers: deny),
            "/child-two": .html("<!doctype html><title>Replacement child</title>")
        ])
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = HeldChildLivenessWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let page = BrowserPage(webKit: webView)
        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        let world = PageAutomationGuard.world
        for name in [
            PageFrameRegistry.handlerName,
            PageFrameRegistry.acknowledgementHandlerName,
            PageFrameRegistry.resumeHandlerName
        ] {
            controller.removeScriptMessageHandler(forName: name, contentWorld: world)
        }
        PageFrameRegistry.install(in: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        var components = try #require(URLComponents(
            url: try server.url("/restore"), resolvingAgainstBaseURL: false
        ))
        components.host = "localhost"
        let restoreURL = try #require(components.url)
        components.path = "/other"
        let otherURL = try #require(components.url)
        components.path = "/replacement"
        let replacementURL = try #require(components.url)
        try await withPage(page, window: window, cleanup: {
            webView.releaseHeldChildLiveness()
        }) {
            page.load(URLRequest(url: restoreURL))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let original = try await mainFrame(in: page)
            var candidateChild: PageFrameRegistry.Target?
            try #require(await waitUntil {
                candidateChild = await PageFrameRegistry.shared.targets(in: page)
                    .first { $0.url.path == "/child" }
                return candidateChild != nil
            })
            let originalChild = try #require(candidateChild)
            webView.holdChildLiveness = true

            page.load(URLRequest(url: otherURL))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            page.goBack()
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil { webView.didHoldChildLiveness })
            try #require(await page.evaluateJavaScript("globalThis.__restored === true") as? Bool == true)
            #expect(webView.heldLivenessValue as? Bool == true, "The held result comes from the real native child-frame evaluation.")

            page.load(URLRequest(url: replacementURL))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil {
                PageFrameRegistry.shared.mainFrame(in: page)?.request.url?.path == "/replacement"
            })
            var candidateReplacementChild: PageFrameRegistry.Target?
            try #require(await waitUntil {
                candidateReplacementChild = await PageFrameRegistry.shared.targets(in: page)
                    .first { $0.url.path == "/child-two" }
                return candidateReplacementChild != nil
            })
            let replacementChild = try #require(candidateReplacementChild)
            let replacementFrame = try #require(PageFrameRegistry.shared.mainFrame(in: page))
            let replacementNonce = replacementFrame.documentID
            try #require(replacementNonce != original.documentID)

            webView.releaseHeldChildLiveness()
            try #require(await waitUntil {
                let targets = await PageFrameRegistry.shared.targets(in: page)
                return PageFrameRegistry.shared.mainFrame(in: page)?.documentID == replacementNonce
                    && targets.contains { $0.id == replacementChild.id && $0.root == replacementNonce }
            })
            let targets = await PageFrameRegistry.shared.targets(in: page)
            #expect(targets.contains { $0.id == replacementChild.id && $0.root == replacementNonce })
            #expect(!targets.contains { $0.id == originalChild.id })
            #expect(PageFrameRegistry.shared.mainFramePolicyAllows(
                replacementFrame, feature: "publickey-credentials-get", in: page
            ) == false)
        }
    }

    @Test(.boundedWebViews)
    @MainActor
    func delayedBackForwardResumeCannotReplaceANewSameOriginDocumentsNonceOrPolicy() async throws {
        let allow = ["Permissions-Policy": "publickey-credentials-get=(self)"]
        let deny = ["Permissions-Policy": "publickey-credentials-get=()"]
        let server = try await HTTPFixtureServer.start(routes: [
            "/restore": .html("""
            <!doctype html><title>Restored</title>
            <script>addEventListener('pageshow', event => { if (event.persisted) globalThis.__persisted = true; });</script>
            """, headers: allow),
            "/other": .html("<!doctype html><title>Other</title>", headers: allow),
            "/replacement": .html("<!doctype html><title>Replacement</title>", headers: deny)
        ])
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = BrowserTab(adopting: webView, opensBlank: false, privately: false)
        let page = tab.page
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        let held = HeldRegistryReplies(controller: configuration.userContentController)
        let world = PageAutomationGuard.world
        var capabilityDocument: String?
        page.addScriptMessageHandler(name: WebAuthnScript.handlerName, in: world) { [weak page] message in
            guard let body = message.body as? [String: Any],
                  body["action"] as? String == "request",
                  body["operation"] as? String == "capabilities",
                  let id = body["id"] as? String,
                  let document = body["document"] as? String,
                  let page else { return }
            capabilityDocument = document
            Task { @MainActor in
                _ = try? await page.callAsyncJavaScript(
                    """
                    return globalThis.__wsurfWebAuthnFence.deliver(
                      documentID, id, {result: {provider: 'manager', enabled: true, canVerifyUser: true}}
                    );
                    """,
                    arguments: ["documentID": document, "id": id],
                    in: nil,
                    contentWorld: world
                )
            }
        }
        page.installScript(
            WebAuthnScript.relay(nativeNonce: true), in: world,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        page.installScript(
            WebAuthnScript.page, in: .page,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        held.install()
        try await withPage(page, window: window) {
            page.load(URLRequest(url: try server.url("/restore")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let original = try await mainFrame(in: page)
            let originalNonce = original.documentID
            _ = try await page.evaluateJavaScript("""
            PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(value => {
              globalThis.__initialCapabilityQuery = value;
            });
            true
            """)
            try #require(await waitUntil { capabilityDocument == originalNonce })
            try #require(await waitUntil {
                (try? await page.evaluateJavaScript("globalThis.__initialCapabilityQuery === true")) as? Bool == true
            })
            #expect(PageFrameRegistry.shared.mainFramePolicyAllows(
                original, feature: "publickey-credentials-get", in: page
            ) == true)

            page.load(URLRequest(url: try server.url("/other")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            page.goBack()
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await page.evaluateJavaScript("globalThis.__persisted === true") as? Bool == true)
            try #require(await waitUntil { held.hasHeldResume })

            page.load(URLRequest(url: try server.url("/replacement")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil { held.hasHeldReplacementAcknowledgement })
            #expect(page.url?.path == "/replacement")
            let replacementNonce = try #require(
                await page.callAsyncJavaScript(
                    "return globalThis.__wsurfNativeFrameNonce;",
                    in: nil,
                    contentWorld: PageAutomationGuard.world
                ) as? String
            )
            try #require(replacementNonce != originalNonce)

            held.releaseResume()
            try #require(await waitUntil { held.didCompleteResume })
            #expect(held.resumeResult as? Bool == false, "The stale resume must be rejected while the replacement ACK remains held.")
            held.releaseReplacementAcknowledgement()
            #expect(await waitUntil { PageFrameRegistry.shared.mainFrame(in: page) != nil })
            let current = try #require(PageFrameRegistry.shared.mainFrame(in: page))
            #expect(current.documentID == replacementNonce)
            #expect(PageFrameRegistry.shared.mainFramePolicyAllows(
                current, feature: "publickey-credentials-get", in: page
            ) == false)
        }
    }

    @Test(.boundedWebViews)
    @MainActor
    func lateFirstResumeCannotSettleTheSecondBackForwardEpoch() async throws {
        let allow = ["Permissions-Policy": "publickey-credentials-get=(self)"]
        let server = try await HTTPFixtureServer.start(routes: [
            "/restore": .html("""
            <!doctype html><title>Restore</title>
            <script>addEventListener('pageshow', event => { if (event.persisted) globalThis.__restoredCount = (globalThis.__restoredCount || 0) + 1; });</script>
            """, headers: allow),
            "/other": .html("<!doctype html><title>Other</title>", headers: allow),
            "/replacement": .html("<!doctype html><title>Replacement</title>", headers: allow)
        ])
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = BrowserTab(adopting: webView, opensBlank: false, privately: false)
        let page = tab.page
        var navigationTrace: [String] = []
        page.onNavigationStarted = { [weak page] _, url in
            navigationTrace.append("start url=\(url?.absoluteString ?? "nil") loading=\(page?.isLoading ?? false)")
        }
        page.onNavigationCommitted = { [weak page] _ in
            guard let page else { return }
            let frame = PageFrameRegistry.shared.mainFrame(in: page)
            navigationTrace.append(
                "commit url=\(page.url?.absoluteString ?? "nil") loading=\(page.isLoading) " +
                "main=\(frame?.documentID ?? "nil") \(frame?.request.url?.absoluteString ?? "nil")"
            )
        }
        page.onNavigationFinished = { [weak page] _ in
            guard let page else { return }
            navigationTrace.append("finish url=\(page.url?.absoluteString ?? "nil") loading=\(page.isLoading)")
        }
        page.onNavigationFailed = { _, error in navigationTrace.append("failed \(error)") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        let held = HeldRegistryReplies(controller: configuration.userContentController)
        held.install()
        try await withPage(page, window: window) {
            page.load(URLRequest(url: try server.url("/restore")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let original = try await mainFrame(in: page)
            page.load(URLRequest(url: try server.url("/other")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            page.goBack()
            let restoredIdle = await PageSettle.untilIdle(page, timeout: .seconds(30))
            if !restoredIdle {
                let proof = try? await page.evaluateJavaScript(
                    "({persisted: globalThis.__restoredCount || 0, nonce: globalThis.__wsurfNativeFrameNonce, epoch: globalThis.__wsurfNativeFrameEpoch})"
                )
                let main = PageFrameRegistry.shared.mainFrame(in: page)
                print(
                    "TEMP lateFirstResume: callbacks=\(navigationTrace) loading=\(page.isLoading) " +
                    "webKitLoading=\(webView.isLoading) url=\(page.url?.absoluteString ?? "nil") " +
                    "back=\(page.canGoBack) forward=\(page.canGoForward) " +
                    "historyBack=\(webView.backForwardList.backList.map { $0.url.absoluteString }) " +
                    "persistedProof=\(String(describing: proof)) nativeMain=\(main?.documentID ?? "nil") " +
                    "\(main?.request.url?.absoluteString ?? "nil") held=\(held.heldResumeCount) epochs=\(held.resumeEpochs)"
                )
            }
            try #require(restoredIdle)
            try #require(await waitUntil { held.heldResumeCount == 1 })
            #expect(held.resumeEpochs == [1])

            page.load(URLRequest(url: try server.url("/replacement")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil { held.hasHeldReplacementAcknowledgement })
            held.releaseReplacementAcknowledgement()
            try #require(await waitUntil {
                PageFrameRegistry.shared.mainFrame(in: page)?.request.url?.path == "/replacement"
            })
            page.goBack()
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil { held.heldResumeCount == 2 })
            #expect(held.resumeEpochs == [1, 2])
            let pending = try #require(await page.callAsyncJavaScript(
                """
                return await Promise.race([
                  globalThis.__wsurfNativeFrameReady.then(value => ({value})),
                  new Promise(resolve => setTimeout(() => resolve({pending: true}), 50))
                ]);
                """,
                in: nil,
                contentWorld: PageAutomationGuard.world
            ) as? [String: Any])
            #expect(pending["pending"] as? Bool == true)

            held.releaseResume(at: 0)
            try #require(await waitUntil { held.resumeResults.count == 1 })
            #expect(held.resumeResults[0] as? Bool == false)
            let stillPending = try #require(await page.callAsyncJavaScript(
                """
                return await Promise.race([
                  globalThis.__wsurfNativeFrameReady.then(value => ({value})),
                  new Promise(resolve => setTimeout(() => resolve({pending: true}), 50))
                ]);
                """,
                in: nil,
                contentWorld: PageAutomationGuard.world
            ) as? [String: Any])
            #expect(stillPending["pending"] as? Bool == true)

            held.releaseResume(at: 0)
            try #require(await waitUntil { held.resumeResults.count == 2 })
            if held.resumeResults[1] as? Bool != true {
                let proof = try? await page.callAsyncJavaScript(
                    "return {persisted: globalThis.__restoredCount || 0, nonce: globalThis.__wsurfNativeFrameNonce, epoch: globalThis.__wsurfNativeFrameEpoch};",
                    in: nil, contentWorld: PageAutomationGuard.world
                )
                let main = PageFrameRegistry.shared.mainFrame(in: page)
                print("[TEMP lateFirstResume second] callbacks=\(navigationTrace) loading=\(page.isLoading) webKitLoading=\(webView.isLoading) url=\(page.url?.absoluteString ?? "nil") back=\(page.canGoBack) forward=\(page.canGoForward) historyBack=\(webView.backForwardList.backList.map { $0.url.absoluteString }) proof=\(String(describing: proof)) main=\(main?.documentID ?? "nil") mainURL=\(main?.request.url?.absoluteString ?? "nil") epochs=\(held.resumeEpochs) results=\(held.resumeResults.map { String(describing: $0) })")
            }
            #expect(held.resumeResults[1] as? Bool == true)
            let restored = try await mainFrame(in: page)
            #expect(restored.documentID == original.documentID)
        }
    }

    @Test(.boundedWebViews)
    @MainActor
    func webKitRelaySendsRequestsAgainOnlyAfterARealBackForwardRestoreRevalidatesItsHandshake() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Credential restore</title>"),
            "/next": .html("<!doctype html><title>Next</title>")
        ])
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = BrowserTab(adopting: webView, opensBlank: false, privately: false)
        let page = tab.page
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        var messages: [[String: Any]] = []
        let world = PageAutomationGuard.world
        page.addScriptMessageHandler(name: WebAuthnScript.handlerName, in: world) { [weak page] message in
            guard let body = message.body as? [String: Any] else { return }
            messages.append(body)
            guard body["action"] as? String == "request",
                  body["operation"] as? String == "capabilities",
                  let id = body["id"] as? String,
                  let document = body["document"] as? String,
                  let page else { return }
            Task { @MainActor in
                _ = try? await page.callAsyncJavaScript(
                    """
                    return globalThis.__wsurfWebAuthnFence.deliver(
                      documentID, id, {result: {provider: 'manager', enabled: true, canVerifyUser: true}}
                    );
                    """,
                    arguments: ["documentID": document, "id": id],
                    in: nil,
                    contentWorld: world
                )
            }
        }
        page.installScript(
            WebAuthnScript.relay(nativeNonce: true), in: world,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        // Native announces the provider right after the relay; without it the page script refuses every call.
        page.installScript(
            WebAuthnScript.route("manager", sequence: 1), in: world,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        page.installScript(
            WebAuthnScript.page, in: .page,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        try await withPage(page, window: window) {
            page.load(URLRequest(url: try server.url("/")))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let original = try await mainFrame(in: page)
            let nonce = original.documentID
            _ = try await page.evaluateJavaScript("""
            addEventListener('pageshow', event => {
              if (event.persisted) {
                globalThis.__restoredRequestStarted = true;
                navigator.credentials.get({publicKey: {challenge: new Uint8Array([4, 5, 6])}}).catch(() => {});
              }
            });
            true
            """)

            page.load(URLRequest(url: try server.url("/next")))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            page.goBack()
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let restored = try await mainFrame(in: page)
            let started = try await page.evaluateJavaScript("globalThis.__restoredRequestStarted === true") as? Bool
            #expect(started == true, "The request is made synchronously from the persisted pageshow handler.")
            #expect(restored.documentID == nonce, "A genuine BFCache restore resumes the original document nonce.")
            #expect(await waitUntil {
                messages.filter {
                    $0["action"] as? String == "request" && $0["operation"] as? String != "capabilities"
                        && $0["document"] as? String == nonce
                }.count == 1
            }, "The first relay request waits for the native registry proof.")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    @MainActor
    func nativePolicyDenialBlocksTheRequestedCredentialOperation(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(
            engine: engine,
            permissionsPolicy: "publickey-credentials-create=(), publickey-credentials-get=(self)"
        )
        try await withFixture(fixture) { fixture in
            let frame = try await mainFrame(in: fixture.page)
            var denied = false
            do {
                _ = try await fixture.page.credentialContext(for: frame, operation: .create)
            } catch WebAuthnContextError.policyDenied {
                denied = true
            } catch {}
            #expect(denied)
            let getContext = try await fixture.page.credentialContext(for: frame, operation: .get)
            #expect(getContext.operation == .get)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    @MainActor
    func iframeContextNeedsNativeEffectivePolicyEvidence(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(
            engine: engine,
            body: "<!doctype html><title>Parent</title><iframe src='/child-one'></iframe>"
        )
        try await withFixture(fixture) { fixture in
            guard await waitUntil({ !(await PageFrameRegistry.shared.targets(in: fixture.page)).isEmpty }),
                  let target = await PageFrameRegistry.shared.targets(in: fixture.page).first else {
                throw FixtureError.frameUnavailable
            }
            if engine == .webKit {
                await #expect(throws: (any Error).self) {
                    try await fixture.page.credentialContext(for: target.frame, operation: .get)
                }
            } else {
                let context = try await fixture.page.credentialContext(for: target.frame, operation: .get)
                #expect(context.origin == fixture.origin)
                #expect(context.topOrigin == nil)
                #expect(context.crossOrigin == false)
                try await context.validate()
            }
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    @MainActor
    func crossOriginCreationRequiresConsumableRealActivation(_ engine: BrowserEngine) async throws {
        let childServer = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><button>Continue</button>")
        ])
        var childComponents = try #require(URLComponents(
            url: childServer.url(), resolvingAgainstBaseURL: false
        ))
        childComponents.host = "localhost"
        let childURL = try #require(childComponents.url)
        let childPort = try #require(childURL.port)
        let childOrigin = "http://localhost:\(childPort)"
        let policy = "publickey-credentials-create=(self \"\(childOrigin)\"), publickey-credentials-get=(self \"\(childOrigin)\")"
        let parentServer = try await HTTPFixtureServer.start(routes: [
            "/": .html(
                "<!doctype html><iframe allow=\"publickey-credentials-create *; publickey-credentials-get *\" src=\"\(childOrigin)/\"></iframe>",
                headers: ["Permissions-Policy": policy]
            )
        ])
        var parentComponents = try #require(URLComponents(
            url: parentServer.url(), resolvingAgainstBaseURL: false
        ))
        parentComponents.host = "localhost"
        let parentURL = try #require(parentComponents.url)
        let parentPort = try #require(parentURL.port)
        let page: BrowserPage
        let tab: BrowserTab?
        switch engine {
        case .webKit:
            let configuration = WebViewPool.makeConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 500, height: 400),
                configuration: configuration
            )
            let browserTab = BrowserTab(adopting: webView, opensBlank: false)
            page = browserTab.page
            tab = browserTab
        case .chromium:
            page = BrowserPage(chromium: ChromiumPage(profile: .original()))
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
        try await withPage(page, window: window) {
            _ = tab
            page.load(URLRequest(url: parentURL))
            guard await PageSettle.untilIdle(page, timeout: .seconds(30)),
                  await waitUntil({
                      (await PageFrameRegistry.shared.targets(in: page)).contains { $0.url.port == childPort }
                  }),
                  let child = await PageFrameRegistry.shared.targets(in: page).first(where: { $0.url.port == childPort }) else {
                throw FixtureError.frameUnavailable
            }
            if engine == .chromium {
                let devTools = try #require(page.chromium).devTools
                let frameID = try #require(child.frame.chromiumID)
                let frameTree = try await devTools.command("Page.getFrameTree")
                let policyState = try await devTools.command(
                    "Page.getPermissionsPolicyState", params: ["frameId": frameID]
                )
                print(
                    "TEMP crossOriginCreation: selectedID=\(frameID) parentID=\(child.frame.chromiumParentID ?? "nil") " +
                    "url=\(child.frame.request.url?.absoluteString ?? "nil") origin=" +
                    "\(child.frame.securityOrigin.protocol)://\(child.frame.securityOrigin.host):\(child.frame.securityOrigin.port) " +
                    "target=\(child.id) root=\(child.root) tree=\(frameTree) policy=\(policyState)"
                )
            }
            if engine == .webKit {
                await #expect(throws: (any Error).self) {
                    try await page.credentialContext(for: child.frame, operation: .create)
                }
            } else {
                let devTools = try #require(page.chromium).devTools
                var activationRejected = false
                do {
                    _ = try await page.credentialContext(for: child.frame, operation: .create)
                } catch WebAuthnContextError.crossOriginCreationRequiresActivation {
                    activationRejected = true
                }
                #expect(activationRejected)
                let context = try await page.credentialContext(for: child.frame, operation: .get)
                #expect(context.crossOrigin)
                #expect(context.topOrigin == "http://localhost:\(parentPort)")

                for type in ["mousePressed", "mouseReleased"] {
                    _ = try await devTools.command("Input.dispatchMouseEvent", params: [
                        "type": type, "x": 30, "y": 30, "button": "left", "clickCount": 1
                    ])
                }
                #expect(try await devTools.transientUserActivationIsActive(
                    in: child.frame, world: PageAutomationGuard.world
                ))
                var consumptionUnsupported = false
                do {
                    _ = try await page.credentialContext(for: child.frame, operation: .create)
                } catch WebAuthnContextError.crossOriginCreationActivationCannotBeConsumed {
                    consumptionUnsupported = true
                }
                #expect(consumptionUnsupported)
            }
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    @MainActor
    func childDocumentReplacementKeepsTheMainContextAndRetiresTheOldChild(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(
            engine: engine,
            body: "<!doctype html><title>Parent</title><iframe src='/child-one'></iframe>"
        )
        try await withFixture(fixture) { fixture in
            let main = try await mainFrame(in: fixture.page)
            let mainContext = try await fixture.page.credentialContext(for: main, operation: .get)
            let originalTopURL = fixture.page.url
            let oldChild: BrowserFrame
            let oldTarget: PageFrameRegistry.Target?
            if engine == .webKit {
                var target: PageFrameRegistry.Target?
                try #require(await waitUntil {
                    target = await PageFrameRegistry.shared.targets(in: fixture.page)
                        .first { $0.url.path == "/child-one" }
                    return target != nil
                })
                let verifiedTarget = try #require(target)
                oldTarget = verifiedTarget
                oldChild = verifiedTarget.frame
            } else {
                oldTarget = nil
                var frame: BrowserFrame?
                try #require(await waitUntil {
                    frame = try? await fixture.page.chromium?.frames()
                        .first { $0.request.url?.path == "/child-one" }
                    return frame != nil
                })
                oldChild = try #require(frame)
            }
            let childContext = engine == .chromium
                ? try await fixture.page.credentialContext(for: oldChild, operation: .get)
                : nil

            _ = try await fixture.page.evaluateJavaScript("document.querySelector('iframe').src = '/child-two'")
            if engine == .webKit {
                try #require(await waitUntil {
                    await PageFrameRegistry.shared.targets(in: fixture.page)
                        .contains { $0.url.path == "/child-two" }
                })
            } else {
                try #require(await waitUntil {
                    (try? await fixture.page.chromium?.frames()
                        .contains { $0.request.url?.path == "/child-two" }) == true
                })
            }

            #expect(fixture.page.url == originalTopURL)
            try await mainContext.validate()
            if let childContext {
                await #expect(throws: (any Error).self) {
                    try await childContext.validate()
                }
            }
            if let oldTarget {
                #expect(await PageFrameRegistry.shared.isLive(oldTarget, in: fixture.page) == false)
            }
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    @MainActor
    func finalDispatchRevalidationPreventsStaleJavaScript(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(engine: engine)
        try await withFixture(fixture) { fixture in
            let frame = try await mainFrame(in: fixture.page)
            let context = try await fixture.page.credentialContext(for: frame, operation: .get)
            var argumentsPrepared = false
            var rejected = false
            do {
                _ = try await fixture.page.callAsyncJavaScript(
                    "globalThis.__wsurfDispatchMustNotRun = value;",
                    in: frame,
                    contentWorld: .page,
                    prepareArguments: {
                        argumentsPrepared = true
                        fixture.page.invalidateCredentialContexts()
                        return ["value": true]
                    },
                    dispatchCheck: { try context.validateForDispatch() }
                )
            } catch {
                rejected = true
            }
            #expect(argumentsPrepared)
            #expect(rejected)
            let result = try await fixture.page.evaluateJavaScript("typeof globalThis.__wsurfDispatchMustNotRun")
            #expect(result as? String == "undefined")
        }
    }
}
