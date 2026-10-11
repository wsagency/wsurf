// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

extension WebAuthnContextTests {
    @Test(.requiresBackForwardCache)
    func mainFrameHistoryEntryCreatedBeforeRegistryAcknowledgmentRestoresItsDocument() async throws {
        let fixture = try await loadPage(engine: .webKit, pushBeforeRegistryAck: true)
        try await withFixture(fixture) {
            let tab = try #require(fixture.tab)
            let originalFrame = try await mainFrame(in: fixture.page)
            #expect(try await fixture.page.evaluateJavaScript("location.hash") as? String == "#before-registry-ack")

            fixture.page.load(URLRequest(url: try fixture.server.url("/next")))
            #expect(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            tab.goBack()
            #expect(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            try #require(await waitUntil {
                (try? await fixture.page.evaluateJavaScript("globalThis.__wsurfPersistedForTest") as? Bool) == true
            }, "WebKit did not restore the pre-ack history entry from its back/forward cache")

            let restoredFrame = try await mainFrame(in: fixture.page)
            #expect(restoredFrame.documentID == originalFrame.documentID)
            let context = try await fixture.page.credentialContext(for: restoredFrame, operation: .get)
            try await context.validate()
        }
    }

    @Test(.requiresBackForwardCache)
    func lateFirstResumeCannotSettleTheSecondBackForwardEpoch() async throws {
        let allow = ["Permissions-Policy": "publickey-credentials-get=(self)"]
        let server = try await HTTPFixtureServer.start(routes: [
            "/restore": .html("<!doctype html><title>Restore</title>", headers: allow),
            "/other": .html("<!doctype html><title>Other</title>", headers: allow),
            "/replacement": .html("<!doctype html><title>Replacement</title>", headers: allow),
        ])
        let configuration = fixtureWebKitConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = ownedWebKitTab(webView)
        let page = tab.page
        let window = host(page)
        let held = HeldRegistryReplies(controller: configuration.userContentController)
        held.install()
        try await withPage(page, window: window, tab: tab) {
            page.load(URLRequest(url: try localURL(server, path: "/restore")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let original = try await mainFrame(in: page)
            page.load(URLRequest(url: try localURL(server, path: "/other")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            page.goBack()
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil { held.heldResumeCount == 1 })
            #expect(held.resumeEpochs == [1])

            page.load(URLRequest(url: try localURL(server, path: "/replacement")))
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

            held.releaseResume()
            try #require(await waitUntil { held.resumeResults.count == 2 })
            #expect(held.resumeResults[1] as? Bool == true)
            let restored = try await mainFrame(in: page)
            #expect(restored.documentID == original.documentID)
        }
    }

    @Test(.requiresBackForwardCache)
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
            "/child-two": .html("<!doctype html><title>Replacement child</title>"),
        ])
        let configuration = fixtureWebKitConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = HeldChildLivenessWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = ownedWebKitTab(webView)
        let page = tab.page
        let window = host(page)
        try await withPage(page, window: window, tab: tab, cleanup: {
            webView.releaseHeldChildLiveness()
        }) {
            page.load(URLRequest(url: try localURL(server, path: "/restore")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let original = try await mainFrame(in: page)
            var candidateChild: PageFrameRegistry.Target?
            try #require(await waitUntil {
                candidateChild = await PageFrameRegistry.shared.targets(in: page).first { $0.url.path == "/child" }
                return candidateChild != nil
            })
            let originalChild = try #require(candidateChild)
            webView.holdChildLiveness = true

            page.load(URLRequest(url: try localURL(server, path: "/other")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            page.goBack()
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil { webView.didHoldChildLiveness })
            try #require(await page.evaluateJavaScript("globalThis.__restored === true") as? Bool == true)
            #expect(webView.heldLivenessValue as? Bool == true)
            let restoredMain = try await mainFrame(in: page)
            #expect(restoredMain.documentID == original.documentID)
            let restoredContext = try await page.credentialContext(for: restoredMain, operation: .get)
            try await restoredContext.validate()

            page.load(URLRequest(url: try localURL(server, path: "/replacement")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil {
                PageFrameRegistry.shared.mainFrame(in: page)?.request.url?.path == "/replacement"
            })
            var replacementChild: PageFrameRegistry.Target?
            try #require(await waitUntil {
                replacementChild = await PageFrameRegistry.shared.targets(in: page).first { $0.url.path == "/child-two" }
                return replacementChild != nil
            })
            let restoredChild = try #require(replacementChild)
            let replacementFrame = try #require(PageFrameRegistry.shared.mainFrame(in: page))
            let replacementNonce = replacementFrame.documentID
            try #require(replacementNonce != original.documentID)

            webView.releaseHeldChildLiveness()
            try #require(await waitUntil {
                let targets = await PageFrameRegistry.shared.targets(in: page)
                return PageFrameRegistry.shared.mainFrame(in: page)?.documentID == replacementNonce
                    && targets.contains { $0.id == restoredChild.id && $0.root == replacementNonce }
            })
            let targets = await PageFrameRegistry.shared.targets(in: page)
            #expect(targets.contains { $0.id == restoredChild.id && $0.root == replacementNonce })
            #expect(!targets.contains { $0.id == originalChild.id })
            #expect(PageFrameRegistry.shared.mainFramePolicyAllows(
                replacementFrame, feature: "publickey-credentials-get", in: page
            ) == false)
        }
    }

    @Test(.requiresBackForwardCache)
    func delayedBackForwardResumeCannotReplaceANewSameOriginDocumentsNonceOrPolicy() async throws {
        let allow = ["Permissions-Policy": "publickey-credentials-get=(self)"]
        let deny = ["Permissions-Policy": "publickey-credentials-get=()"]
        let server = try await HTTPFixtureServer.start(routes: [
            "/restore": .html("""
            <!doctype html><title>Restored</title>
            <script>addEventListener('pageshow', event => { if (event.persisted) globalThis.__persisted = true; });</script>
            """, headers: allow),
            "/other": .html("<!doctype html><title>Other</title>", headers: allow),
            "/replacement": .html("<!doctype html><title>Replacement</title>", headers: deny),
        ])
        let configuration = fixtureWebKitConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = ownedWebKitTab(webView)
        let page = tab.page
        let window = host(page)
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
        page.installScript(WebAuthnScript.relay(nativeNonce: true), in: world,
                           injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(WebAuthnScript.page, in: .page,
                           injectionTime: .atDocumentStart, forMainFrameOnly: false)
        held.install()
        try await withPage(page, window: window, tab: tab) {
            page.load(URLRequest(url: try localURL(server, path: "/restore")))
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

            page.load(URLRequest(url: try localURL(server, path: "/other")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            page.goBack()
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await page.evaluateJavaScript("globalThis.__persisted === true") as? Bool == true)
            try #require(await waitUntil { held.heldResumeCount == 1 })

            page.load(URLRequest(url: try localURL(server, path: "/replacement")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil { held.hasHeldReplacementAcknowledgement })
            #expect(page.url?.path == "/replacement")
            let replacementNonce = try #require(
                await page.callAsyncJavaScript(
                    "return globalThis.__wsurfNativeFrameNonce;",
                    in: nil,
                    contentWorld: world
                ) as? String
            )
            try #require(replacementNonce != originalNonce)

            held.releaseResume()
            try #require(await waitUntil { held.resumeResults.count == 1 })
            #expect(held.resumeResults[0] as? Bool == false)
            held.releaseReplacementAcknowledgement()
            try #require(await waitUntil { PageFrameRegistry.shared.mainFrame(in: page) != nil })
            let current = try #require(PageFrameRegistry.shared.mainFrame(in: page))
            #expect(current.documentID == replacementNonce)
            #expect(PageFrameRegistry.shared.mainFramePolicyAllows(
                current, feature: "publickey-credentials-get", in: page
            ) == false)
        }
    }

    @Test(.requiresBackForwardCache)
    func historyAPIURLChangesSurviveBackForwardCredentialContextRestore() async throws {
        let fixture = try await loadPage(engine: .webKit)
        try await withFixture(fixture) {
            let tab = try #require(fixture.tab)
            let original = try await mainFrame(in: fixture.page)
            _ = try await fixture.page.evaluateJavaScript("""
            globalThis.__restoredPersisted = false;
            addEventListener('pageshow', event => {
              if (event.isTrusted && event.persisted) globalThis.__restoredPersisted = true;
            });
            history.replaceState({stage: 'replace'}, '', '/replaced');
            history.pushState({stage: 'push'}, '', '/pushed');
            location.hash = 'restored';
            true
            """)

            fixture.page.load(URLRequest(url: try localURL(fixture.server, path: "/next")))
            try #require(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            tab.goBack()
            try #require(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            try #require(await waitUntil {
                (try? await fixture.page.evaluateJavaScript("globalThis.__restoredPersisted === true")) as? Bool == true
            })
            #expect(fixture.page.url?.path == "/pushed")
            #expect(fixture.page.url?.fragment == "restored")
            let restored = try await mainFrame(in: fixture.page)
            #expect(restored.documentID == original.documentID)
            let restoredContext = try await fixture.page.credentialContext(for: restored, operation: .get)
            try await restoredContext.validate()

            _ = try await fixture.page.evaluateJavaScript("history.go(-1)")
            try #require(await waitUntil {
                fixture.page.url?.path == "/pushed" && fixture.page.url?.fragment == nil
            })
            try #require(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            let sameDocument = try await mainFrame(in: fixture.page)
            #expect(sameDocument.documentID == restored.documentID)
            #expect(sameDocument.documentID == original.documentID)
            let currentContext = try await fixture.page.credentialContext(for: sameDocument, operation: .get)
            try await currentContext.validate()
        }
    }

    @Test
    func historyAPIPushStateEarlierEntryKeepsItsCredentialBoundary() async throws {
        let fixture = try await loadPage(engine: .webKit, recordTrustedPageShows: true)
        try await withFixture(fixture) {
            let original = try await mainFrame(in: fixture.page)
            let originalContext = try await fixture.page.credentialContext(for: original, operation: .get)
            try await originalContext.validate()
            _ = try await fixture.page.evaluateJavaScript("""
            history.replaceState({stage: 'replace'}, '', '/replaced');
            history.pushState({stage: 'push'}, '', '/pushed');
            location.hash = 'restored';
            true
            """)

            fixture.page.load(URLRequest(url: try localURL(fixture.server, path: "/next")))
            try #require(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            _ = try await fixture.page.evaluateJavaScript("history.go(-2)")
            try #require(await waitUntil { fixture.page.url?.path == "/pushed" })
            try #require(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            try #require(await waitUntil {
                (try? await fixture.page.evaluateJavaScript("""
                (globalThis.__wsurfPageShowsForTest || []).some(event =>
                  event.path === '/pushed' && event.trusted === true
                )
                """)) as? Bool == true
            }, "The result document did not report a trusted pageshow")

            #expect(fixture.page.url?.path == "/pushed")
            #expect(fixture.page.url?.fragment == nil)
            let resultFrame = try await mainFrame(in: fixture.page)
            #expect(resultFrame.request.url?.path == "/pushed")
            let pageShows = try #require(
                await fixture.page.evaluateJavaScript("globalThis.__wsurfPageShowsForTest") as? [[String: Any]]
            )
            let resultPageShow = try #require(pageShows.last { $0["path"] as? String == "/pushed" })
            #expect(resultPageShow["trusted"] as? Bool == true)
            let persisted = try #require(resultPageShow["persisted"] as? Bool)

            var oldContextIsStale = false
            do {
                try await originalContext.validate()
            } catch WebAuthnContextError.staleFrame {
                oldContextIsStale = true
            } catch {}
            #expect(oldContextIsStale)

            if persisted {
                #expect(resultFrame.documentID == original.documentID)
                #expect(PageFrameRegistry.shared.mainFramePolicyAllows(
                    resultFrame, feature: "publickey-credentials-get", in: fixture.page
                ) == true)
                let currentContext = try await fixture.page.credentialContext(for: resultFrame, operation: .get)
                try await currentContext.validate()
            } else {
                #expect(resultFrame.documentID != original.documentID)
                #expect(PageFrameRegistry.shared.mainFrame(in: fixture.page)?.documentID != original.documentID)
                #expect(PageFrameRegistry.shared.mainFramePolicyAllows(
                    resultFrame, feature: "publickey-credentials-get", in: fixture.page
                ) == nil)
                var policyUnavailable = false
                do {
                    _ = try await fixture.page.credentialContext(for: resultFrame, operation: .get)
                } catch WebAuthnContextError.policyUnavailable {
                    policyUnavailable = true
                } catch {}
                #expect(policyUnavailable)
            }
        }
    }

    @Test
    func backForwardRestoreReestablishesMainFramePolicyAndNonce() async throws {
        let fixture = try await loadPage(engine: .webKit)
        try await withFixture(fixture) {
            let tab = try #require(fixture.tab)
            let original = try await mainFrame(in: fixture.page)
            _ = try await fixture.page.evaluateJavaScript(
                "globalThis.__wsurfPersistedTest = false; addEventListener('pageshow', event => { globalThis.__wsurfPersistedTest = event.persisted; });"
            )
            fixture.page.load(URLRequest(url: try localURL(fixture.server, path: "/next")))
            #expect(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            tab.goBack()
            #expect(await PageSettle.untilIdle(fixture.page, timeout: .seconds(30)))
            let restored = try await mainFrame(in: fixture.page)
            let persisted = try await fixture.page.evaluateJavaScript(
                "globalThis.__wsurfPersistedTest === true"
            ) as? Bool
            if persisted == true {
                #expect(restored.documentID == original.documentID)
            } else {
                #expect(restored.documentID != original.documentID)
            }
            let context = try await fixture.page.credentialContext(for: restored, operation: .get)
            try await context.validate()
        }
    }

    @Test(.requiresBackForwardCache)
    func registryRestoresMainAndHTTPChildWithoutCredentialRelay() async throws {
        let allow = ["Permissions-Policy": "publickey-credentials-get=(self)"]
        let server = try await HTTPFixtureServer.start(routes: [
            "/restore": .html("""
            <!doctype html><title>Restore</title><iframe src="/child"></iframe>
            <script>addEventListener('pageshow', event => { if (event.persisted) globalThis.__restored = true; });</script>
            """, headers: allow),
            "/child": .html("<!doctype html><title>Child</title>"),
            "/other": .html("<!doctype html><title>Other</title>", headers: allow),
        ])
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
            page.load(URLRequest(url: try localURL(server, path: "/restore")))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let original = try await mainFrame(in: page)
            try #require(await waitUntil {
                await PageFrameRegistry.shared.targets(in: page).contains { $0.url.path == "/child" }
            })
            let originalChild = try #require(
                await PageFrameRegistry.shared.targets(in: page).first { $0.url.path == "/child" }
            )

            page.load(URLRequest(url: try localURL(server, path: "/other")))
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
                contentWorld: PageAutomationGuard.world
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

    @Test(.requiresBackForwardCache)
    func webKitRelaySendsRequestsAgainOnlyAfterARealBackForwardRestoreRevalidatesItsHandshake() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Credential restore</title>"),
            "/next": .html("<!doctype html><title>Next</title>"),
        ])
        let configuration = fixtureWebKitConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let tab = ownedWebKitTab(webView)
        let page = tab.page
        let window = host(page)
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
        try await withPage(page, window: window, tab: tab) {
            page.context.settings.passwordProvider = .credentialManager
            page.load(URLRequest(url: try localURL(server, path: "/")))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let routeScript = """
            (() => { let route = null; const note = event => { route = event.detail; };
              document.addEventListener('wsurf-webauthn-route', note);
              document.dispatchEvent(new CustomEvent('wsurf-webauthn-route-request'));
              document.removeEventListener('wsurf-webauthn-route', note);
              return route;
            })()
            """
            try #require(await waitUntil {
                (try? await page.evaluateJavaScript(routeScript)) as? String == "manager"
            })
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

            page.load(URLRequest(url: try localURL(server, path: "/next")))
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

    @Test(arguments: BrowserEngine.allCases)
    func nativePolicyDenialBlocksTheRequestedCredentialOperation(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(
            engine: engine,
            permissionsPolicy: "publickey-credentials-create=(), publickey-credentials-get=(self)"
        )
        try await withFixture(fixture) {
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

    @Test(arguments: BrowserEngine.allCases)
    func iframeContextNeedsNativeEffectivePolicyEvidence(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(
            engine: engine,
            body: "<!doctype html><title>Parent</title><iframe src='/child-one'></iframe>"
        )
        try await withFixture(fixture) {
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

    @Test(arguments: BrowserEngine.allCases)
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
            ),
        ])
        var parentComponents = try #require(URLComponents(
            url: parentServer.url(), resolvingAgainstBaseURL: false
        ))
        parentComponents.host = "localhost"
        let parentURL = try #require(parentComponents.url)
        let parentPort = try #require(parentURL.port)
        let profileContext = BrowserProfileContext(profile: Profile(
            id: UUID(), name: "Cross-origin fixture", symbol: "key", color: .blue
        ))
        let page: BrowserPage
        let tab: BrowserTab?
        switch engine {
        case .webKit:
            let configuration = fixtureWebKitConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 500, height: 400),
                configuration: configuration
            )
            let browserTab = BrowserTab(
                adopting: webView, opensBlank: false, privately: false, context: profileContext
            )
            page = browserTab.page
            tab = browserTab
        case .chromium:
            page = BrowserPage(chromium: ChromiumPage(context: profileContext))
            tab = nil
        }
        let window = host(page)
        try await withPage(page, window: window) {
            _ = tab
            page.load(URLRequest(url: parentURL))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil {
                (await PageFrameRegistry.shared.targets(in: page)).contains { $0.url.port == childPort }
            })
            let child = try #require(
                await PageFrameRegistry.shared.targets(in: page).first { $0.url.port == childPort }
            )
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

    @Test(arguments: BrowserEngine.allCases)
    func childDocumentReplacementKeepsTheMainContextAndRetiresTheOldChild(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(
            engine: engine,
            body: "<!doctype html><title>Parent</title><iframe src='/child-one'></iframe>"
        )
        try await withFixture(fixture) {
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

    @Test(arguments: BrowserEngine.allCases)
    func finalDispatchRevalidationPreventsStaleJavaScript(_ engine: BrowserEngine) async throws {
        let fixture = try await loadPage(engine: engine)
        try await withFixture(fixture) {
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
