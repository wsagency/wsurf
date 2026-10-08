// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews, .exclusiveExternalApp, .timeLimit(.minutes(1)))
struct AppHandoffTests {
    private func asked(
        for route: String,
        routes: [String: HTTPFixtureServer.Response],
        expectedOrigin: String? = nil
    ) async throws -> URL? {
        let server = try await HTTPFixtureServer.start(routes: routes)
        let (openedURLs, continuation) = AsyncStream<URL>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ExternalApp.requestObserverForTesting = { url, origin in
            #expect(origin == (expectedOrigin ?? SitePermissions.origin(for: try? server.url(route))))
            continuation.yield(url)
        }
        defer {
            ExternalApp.requestObserverForTesting = nil
            continuation.finish()
        }

        let tab = BrowserTab(opensBlank: false)
        defer {
            tab.detach()
            withExtendedLifetime(server) {}
        }
        tab.load(try server.url(route))
        var iterator = openedURLs.makeAsyncIterator()
        return await iterator.next()
    }

    @Test func aScriptedJumpToAnAppIsOffered() async throws {
        let seen = try await asked(for: "/js", routes: [
            "/js": .html("<title>Go</title><script>location.href='slack://open'</script>"),
        ])
        #expect(seen?.scheme == "slack")
    }

    @Test func aJumpFromAFrameIsOfferedToo() async throws {
        let seen = try await asked(for: "/frame", routes: [
            "/frame": .html("<title>Go</title><iframe src='slack://open'></iframe>"),
        ])
        #expect(seen?.scheme == "slack", "a hidden frame is how a sign-in page usually hands back")
    }

    @Test func aRedirectStraightToAnAppIsOffered() async throws {
        let seen = try await asked(for: "/redirect", routes: [
            "/redirect": .redirect(to: URL(string: "slack://open")!),
        ])
        #expect(seen?.scheme == "slack")
    }

    @Test(arguments: [false, true])
    func anInitialRedirectCannotFinishAfterAnotherNavigationStarts(suspendedAtPresenter: Bool) async throws {
        let response = ResponseGate()
        let server = try await HTTPFixtureServer.start(routes: [
            "/redirect": .redirect(to: URL(string: "slack://open")!),
            "/waiting": .html("<title>Next navigation</title>", gate: response),
        ])
        let file = URL.temporaryDirectory.appending(path: "InitialRedirectApp-\(UUID().uuidString).json")
        let store = SitePermissions(storageURL: file)
        let tab = BrowserTab(opensBlank: false, privately: true, sitePermissions: store)
        var resolver: CheckedContinuation<ExternalApp.Match?, Never>?
        var presenter: CheckedContinuation<NSApplication.ModalResponse, Never>?
        var prompts = 0
        var opened: [URL] = []
        ExternalApp.resolverForTesting = { _ in
            if suspendedAtPresenter {
                return .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")
            }
            return await withCheckedContinuation { resolver = $0 }
        }
        ExternalApp.presenterForTesting = { alert in
            prompts += 1
            alert.suppressionButton?.state = .on
            return await withCheckedContinuation { presenter = $0 }
        }
        ExternalApp.openerForTesting = { opened.append($0) }
        defer {
            resolver?.resume(returning: nil)
            presenter?.resume(returning: .alertSecondButtonReturn)
            ExternalApp.resolverForTesting = nil
            ExternalApp.presenterForTesting = nil
            ExternalApp.openerForTesting = nil
            response.open()
            tab.detach()
            try? FileManager.default.removeItem(at: file)
            withExtendedLifetime(server) {}
        }
        tab.load(try server.url("/redirect"))
        try #require(await waitUntil { suspendedAtPresenter ? presenter != nil : resolver != nil })
        #expect(tab.committedNavigation == nil)
        tab.load(try server.url("/waiting"))
        try #require(await waitUntil { response.requestCount == 1 })
        #expect(tab.committedNavigation == nil)
        if suspendedAtPresenter {
            presenter?.resume(returning: .alertFirstButtonReturn)
            presenter = nil
        } else {
            resolver?.resume(returning: .init(
                url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"
            ))
            resolver = nil
        }
        try #require(await waitUntil { !ExternalApp.hasPendingOfferForTesting })
        #expect(prompts == (suspendedAtPresenter ? 1 : 0))
        #expect(opened.isEmpty)
        #expect(store.externalAppRecords.isEmpty)
    }

    @Test func aLinkToAnAppIsOffered() async throws {
        let seen = try await asked(for: "/link", routes: [
            "/link": .html(
                "<title>Go</title><a id='go' href='slack://open'>go</a>"
                    + "<script>document.getElementById('go').click()</script>"
            ),
        ])
        #expect(seen?.scheme == "slack")
    }

    @Test func aCrossOriginFrameUsesItsOwnOrigin() async throws {
        let frameServer = try await HTTPFixtureServer.start(routes: [
            "/frame": .html("<script>location.href='slack://open'</script>"),
        ])
        defer { withExtendedLifetime(frameServer) {} }
        let frameURL = try frameServer.url("/frame")
        let seen = try await asked(
            for: "/page",
            routes: ["/page": .html("<iframe src='\(frameURL.absoluteString)'></iframe>")],
            expectedOrigin: SitePermissions.origin(for: frameURL)
        )
        #expect(seen?.scheme == "slack")
    }

    @Test func aRedirectChainUsesTheWebsiteThatHandsOffToTheApp() async throws {
        let authServer = try await HTTPFixtureServer.start(routes: [
            "/finish": .redirect(to: URL(string: "slack://open")!),
        ])
        defer { withExtendedLifetime(authServer) {} }
        let authURL = try authServer.url("/finish")
        let seen = try await asked(
            for: "/start",
            routes: ["/start": .redirect(to: authURL)],
            expectedOrigin: SitePermissions.origin(for: authURL)
        )
        #expect(seen?.scheme == "slack")
    }

    @Test func aRedirectAfterALoadedPageUsesTheAuthorizationWebsite() async throws {
        let authServer = try await HTTPFixtureServer.start(routes: [
            "/finish": .redirect(to: URL(string: "slack://open")!),
        ])
        defer { withExtendedLifetime(authServer) {} }
        let authURL = try authServer.url("/finish")
        let seen = try await asked(
            for: "/page",
            routes: ["/page": .html("<script>addEventListener('load', () => location.href='\(authURL.absoluteString)')</script>")],
            expectedOrigin: SitePermissions.origin(for: authURL)
        )
        #expect(seen?.scheme == "slack")
    }

    @Test func aScriptDuringAnotherPageLoadKeepsTheScriptsOrigin() async throws {
        let response = ResponseGate()
        defer { response.open() }
        let waitingServer = try await HTTPFixtureServer.start(routes: [
            "/waiting": .html("<title>Waiting</title>", gate: response),
        ])
        let sourceServer = try await HTTPFixtureServer.start(routes: [
            "/page": .html("<title>Source</title>"),
        ])
        let sourceURL = try sourceServer.url("/page")
        let tab = BrowserTab(opensBlank: false)
        defer {
            tab.detach()
            ExternalApp.requestObserverForTesting = nil
            withExtendedLifetime((sourceServer, waitingServer)) {}
        }
        tab.load(sourceURL)
        try #require(await settled(tab, at: sourceURL))
        tab.load(try waitingServer.url("/waiting"))
        try #require(await waitUntil { response.requestCount == 1 })
        var observedOrigin: String?
        ExternalApp.requestObserverForTesting = { _, origin in observedOrigin = origin }
        _ = try await tab.page.evaluateJavaScript("location.href='slack://open'")
        try #require(await waitUntil { observedOrigin != nil })
        #expect(observedOrigin == SitePermissions.origin(for: sourceURL))
    }

    @Test func aRedirectedIframeCannotReuseItsPreviousDocumentsAppGrant() async throws {
        let destination = URL(string: "slack://open")!
        let app = ExternalAppPermission(scheme: "slack", bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        let authServer = try await HTTPFixtureServer.start(routes: ["/finish": .redirect(to: destination)])
        let authURL = try authServer.url("/finish")
        let frameServer = try await HTTPFixtureServer.start(routes: [
            "/frame": .html("""
                <script>addEventListener('message', () => location.href = '\(authURL.absoluteString)');
                parent.postMessage('ready', '*');</script>
                """),
        ])
        let frameURL = try frameServer.url("/frame")
        let topServer = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <script>addEventListener('message', () => window.frameReady = true);</script>
                <iframe src='\(frameURL.absoluteString)'></iframe>
                """),
        ])
        let file = URL.temporaryDirectory.appending(path: "RedirectApp-\(UUID().uuidString).json")
        let store = SitePermissions(storageURL: file)
        let tab = BrowserTab(opensBlank: false, privately: true, sitePermissions: store)
        defer {
            tab.detach()
            ExternalApp.resolverForTesting = nil
            ExternalApp.presenterForTesting = nil
            ExternalApp.openerForTesting = nil
            try? FileManager.default.removeItem(at: file)
            withExtendedLifetime((authServer, frameServer, topServer)) {}
        }
        let topURL = try topServer.url()
        tab.load(topURL)
        try #require(await settled(tab, at: topURL))
        try #require(await waitUntil { (try? await tab.page.evaluateJavaScript("window.frameReady === true")) as? Bool == true })
        tab.externalApps.remember(app, from: SitePermissions.origin(for: frameURL))
        var prompts = 0
        var opened: [URL] = []
        ExternalApp.resolverForTesting = { _ in
            .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier)
        }
        ExternalApp.presenterForTesting = { alert in
            prompts += 1
            #expect(!alert.showsSuppressionButton)
            return .alertSecondButtonReturn
        }
        ExternalApp.openerForTesting = { opened.append($0) }
        _ = try await tab.page.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage('go', '*'); true")
        try #require(await waitUntil { prompts == 1 })
        #expect(opened.isEmpty)
        #expect(!tab.externalApps.allows(app, from: SitePermissions.origin(for: authURL)))
        #expect(store.externalAppRecords.isEmpty)
    }

    @Test(arguments: [false, true])
    func cefExternalApprovalUsesSourceFrame(targetsMainFrame: Bool) async throws {
        let externalURL = URL(string: "slack://open?code=secret")!
        let app = ExternalAppPermission(scheme: "slack", bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        let response = ResponseGate()
        let steps = (0..<3).map { _ in ResponseGate() }
        defer { steps.forEach { $0.open() } }
        defer { response.open() }
        let frameServer = try await HTTPFixtureServer.start(routes: [
            "/frame": .html("""
                <title>Frame A</title><script>
                addEventListener('message', async e => {
                  if (e.data !== 'handoff') return;
                  for (let step = 0; step < 3; step++) {
                    await fetch('/step-' + step);
                    \(targetsMainFrame ? "top" : "window").location.href = '\(externalURL.absoluteString)';
                  }
                });
                parent.postMessage('ready', '*');
                </script>
                """),
            "/step-0": .html("", gate: steps[0]),
            "/step-1": .html("", gate: steps[1]),
            "/step-2": .html("", gate: steps[2]),
        ])
        let frameURL = try frameServer.url("/frame")
        let topServer = try await HTTPFixtureServer.start(routes: [
            "/page": .html("""
                <title>Top B</title><script>addEventListener('message', e => { if(e.data === 'ready') window.frameReady = true; });</script>
                <iframe src='\(frameURL.absoluteString)'></iframe>
                """),
        ])
        let pendingServer = try await HTTPFixtureServer.start(routes: [
            "/waiting": .html("<title>Pending C</title>", gate: response),
            "/redirect": .redirect(to: externalURL),
        ])
        defer { withExtendedLifetime((frameServer, topServer, pendingServer)) {} }
        let topURL = try topServer.url("/page")
        let pendingURL = try pendingServer.url("/waiting")
        let sourceOrigin = SitePermissions.origin(for: frameURL)
        let topOrigin = SitePermissions.origin(for: topURL)
        let pendingOrigin = SitePermissions.origin(for: pendingURL)
        let file = URL.temporaryDirectory.appending(path: "CEFExternalApp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let permissions = SitePermissions(storageURL: file)
        permissions.setEngine(.chromium, for: topOrigin)
        permissions.setEngine(.chromium, for: pendingOrigin)
        await permissions.waitForPendingSave()
        let tab = BrowserTab(opensBlank: false, privately: true, sitePermissions: permissions)
        defer { tab.detach() }
        tab.load(topURL)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFront(nil)
        defer { window.close() }
        try #require(await settled(tab, at: topURL))
        try #require(tab.page.engine == .chromium)
        try #require(await waitUntil { (try? await tab.page.evaluateJavaScript("window.frameReady === true")) as? Bool == true })
        var prompts = 0
        var opened: [URL] = []
        var redirecting = false
        ExternalApp.resolverForTesting = { _ in
            .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier)
        }
        ExternalApp.openerForTesting = { opened.append($0) }
        ExternalApp.presenterForTesting = { alert in
            prompts += 1
            #expect(alert.showsSuppressionButton == !redirecting)
            #expect(!alert.informativeText.contains("secret"))
            alert.suppressionButton?.state = .on
            return prompts == 1 ? .alertSecondButtonReturn : .alertFirstButtonReturn
        }
        defer {
            ExternalApp.resolverForTesting = nil
            ExternalApp.openerForTesting = nil
            ExternalApp.presenterForTesting = nil
        }
        let chromium = try #require(tab.page.chromium)
        let frames = try await chromium.devTools.frames()
        let sourceFrame = try #require(frames.first { $0.request.url == frameURL })
        _ = try await chromium.devTools.evaluate("window.postMessage('handoff', '*'); true", in: sourceFrame, world: .page)
        try #require(await waitUntil { steps[0].requestCount == 1 })
        tab.load(pendingURL)
        try #require(await waitUntil { response.requestCount == 1 })
        steps[0].open()
        try #require(await waitUntil { prompts == 1 })
        #expect(opened.isEmpty)
        for origin in [sourceOrigin, topOrigin, pendingOrigin] {
            #expect(!tab.externalApps.allows(app, from: origin))
        }
        try #require(await waitUntil { steps[1].requestCount == 1 })
        steps[1].open()
        try #require(await waitUntil { opened.count == 1 })
        #expect(tab.externalApps.allows(app, from: sourceOrigin))
        #expect(!tab.externalApps.allows(app, from: topOrigin))
        #expect(!tab.externalApps.allows(app, from: pendingOrigin))
        try #require(await waitUntil { steps[2].requestCount == 1 })
        steps[2].open()
        try #require(await waitUntil { opened.count == 2 })
        #expect(prompts == 2)
        #expect(opened == [externalURL, externalURL])
        tab.page.stopLoading()
        response.open()
        redirecting = true
        for expected in 3...4 {
            tab.load(try pendingServer.url("/redirect"))
            try #require(await waitUntil { opened.count == expected })
            #expect(prompts == expected)
            #expect(!tab.externalApps.allows(app, from: pendingOrigin))
        }
        #expect(permissions.externalAppRecords.isEmpty)
        #expect(SitePermissions(storageURL: file).externalAppRecords.isEmpty)
        tab.detach()
        await tab.waitForRetirement()
    }

    private enum UnattributedSource: CaseIterable, Sendable {
        case noReferrer
        case duplicateURL
        case originOnly
        case inheritedDocument
        case opaqueOrigin
    }

    @Test(arguments: UnattributedSource.allCases)
    private func cefUnattributedHandoffRequiresOneTimeApproval(_ source: UnattributedSource) async throws {
        let externalURL = URL(string: "slack://open?code=secret")!
        let app = ExternalAppPermission(scheme: "slack", bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        let frameDocument = """
            \(source == .noReferrer ? "<meta name='referrer' content='no-referrer'>" : "")
            \(source == .originOnly ? "<meta name='referrer' content='origin'>" : "")
            <a href='\(externalURL.absoluteString)' target='_top' style='position:fixed;inset:0'>Open</a>
            <script>
            document.querySelector('a').addEventListener('click', event => {
              parent.postMessage({ activation: [event.isTrusted, navigator.userActivation.isActive] }, '*');
            });
            addEventListener('message', e => {
              if (e.data === 'focus') {
                const link = document.querySelector('a');
                link.focus();
                parent.postMessage({ focused: document.activeElement === link }, '*');
                return;
              }
              if (e.data !== 'handoff') return;
              top.location.href = '\(externalURL.absoluteString)';
            });
            parent.postMessage('ready', '*');
            </script>
            """
        let readiness = """
            <script>window.readyFrames = 0; addEventListener('message', e => {
              if (e.data === 'ready') window.readyFrames++;
              if (e.data?.focused) window.opaqueFrameFocused = e.origin === 'null';
              if (e.data?.activation) {
                window.opaqueFrameActivated = e.origin === 'null' && e.data.activation[0] && e.data.activation[1];
              }
            });
            </script>
            """
        let localFrame = source == .inheritedDocument
            ? "<iframe srcdoc=\"\(frameDocument)\"></iframe>"
            : "<iframe \(source == .opaqueOrigin ? "sandbox='allow-scripts allow-top-navigation-by-user-activation'" : "") src='/frame'></iframe>"
        let frameServer = try await HTTPFixtureServer.start(routes: [
            "/frame": .html(frameDocument),
            "/": .html(readiness + localFrame),
        ])
        let frameURL = try frameServer.url("/frame")
        let topServer: HTTPFixtureServer
        if source == .noReferrer || source == .duplicateURL {
            let iframe = "<iframe src='\(frameURL.absoluteString)'></iframe>"
            topServer = try await HTTPFixtureServer.start(routes: [
                "/": .html(readiness + iframe + (source == .duplicateURL ? iframe : "")),
            ])
        } else {
            topServer = frameServer
        }
        let topURL = try topServer.url("/")
        let file = URL.temporaryDirectory.appending(path: "UnattributedCEFApp-\(UUID().uuidString).json")
        let store = SitePermissions(storageURL: file)
        store.setEngine(.chromium, for: SitePermissions.origin(for: topURL))
        let tab = BrowserTab(opensBlank: false, privately: true, sitePermissions: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        var prompts = 0
        var opened: [URL] = []
        ExternalApp.resolverForTesting = { _ in
            .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier)
        }
        ExternalApp.presenterForTesting = { alert in
            prompts += 1
            #expect(!alert.showsSuppressionButton)
            #expect(!alert.informativeText.contains("secret"))
            alert.suppressionButton?.state = .on
            return prompts == 1 ? .alertSecondButtonReturn : .alertFirstButtonReturn
        }
        ExternalApp.openerForTesting = { opened.append($0) }
        defer {
            tab.detach()
            window.close()
            ExternalApp.resolverForTesting = nil
            ExternalApp.presenterForTesting = nil
            ExternalApp.openerForTesting = nil
            try? FileManager.default.removeItem(at: file)
            withExtendedLifetime((frameServer, topServer)) {}
        }
        tab.load(topURL)
        window.contentView = tab.page
        try #require(await settled(tab, at: topURL))
        try #require(tab.page.engine == .chromium)
        try #require(await waitUntil {
            (try? await tab.page.evaluateJavaScript("window.readyFrames")) as? Int == (source == .duplicateURL ? 2 : 1)
        })
        let chromium = try #require(tab.page.chromium)
        func requestHandoff() async throws {
            if source == .opaqueOrigin {
                try await activateOpaqueFrameLink(in: tab)
            } else {
                _ = try await chromium.devTools.evaluate(
                    "document.querySelector('iframe').contentWindow.postMessage('handoff', '*'); true", in: nil, world: .page)
            }
        }
        for expectedPrompts in 1...2 {
            try await requestHandoff()
            try #require(await waitUntil { prompts == expectedPrompts && !ExternalApp.hasPendingOfferForTesting })
            #expect(opened == (expectedPrompts == 1 ? [] : [externalURL]))
            #expect(!tab.externalApps.allows(app, from: SitePermissions.origin(for: frameURL)))
            #expect(!tab.externalApps.allows(app, from: SitePermissions.origin(for: topURL)))
        }
        tab.externalApps.remember(app, from: SitePermissions.origin(for: frameURL))
        tab.externalApps.remember(app, from: SitePermissions.origin(for: topURL))
        try await requestHandoff()
        try #require(await waitUntil { opened.count == 2 && !ExternalApp.hasPendingOfferForTesting })
        #expect(prompts == 3, "an unattributed request cannot reuse another document's remembered approval")
        #expect(opened == [externalURL, externalURL])
        #expect(store.externalAppRecords.isEmpty)
        await store.waitForPendingSave()
        #expect(SitePermissions(storageURL: file).externalAppRecords.isEmpty)
        tab.detach()
        await tab.waitForRetirement()
    }

    private enum FrameMutation: CaseIterable, Sendable {
        case navigate
        case replaceAtSameURL
        case remove

        var script: String {
            switch self {
            case .navigate:
                "const frame = document.querySelector('iframe'); frame.src = new URL('/replacement', frame.src).href"
            case .replaceAtSameURL:
                "const old = document.querySelector('iframe'); old.replaceWith(old.cloneNode())"
            case .remove:
                "document.querySelector('iframe').remove()"
            }
        }
        var settledScript: String {
            switch self {
            case .navigate, .replaceAtSameURL:
                "window.frameLoads > 1"
            case .remove:
                "document.querySelector('iframe') === null"
            }
        }
    }

    @Test(arguments: FrameMutation.allCases)
    private func aStaleWebKitIframeCannotLaunchAfterResolverSuspends(_ mutation: FrameMutation) async throws {
        try await staleWebKitIframeCannotHandoff(mutation, suspendedAtPresenter: false)
    }

    @Test(arguments: FrameMutation.allCases)
    private func aStaleWebKitIframeCannotRememberOrLaunchAfterPresenterSuspends(_ mutation: FrameMutation) async throws {
        try await staleWebKitIframeCannotHandoff(mutation, suspendedAtPresenter: true)
    }

    private func staleWebKitIframeCannotHandoff(
        _ mutation: FrameMutation,
        suspendedAtPresenter: Bool
    ) async throws {
        let app = ExternalAppPermission(scheme: "slack", bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        let frameServer = try await HTTPFixtureServer.start(routes: [
            "/frame": .html("<script>addEventListener('message', () => location.href = 'slack://open'); parent.postMessage('ready', '*')</script>"),
            "/replacement": .html("<title>Replacement</title>"),
        ])
        let frameURL = try frameServer.url("/frame")
        let topServer = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <script>window.frameLoads = 0; addEventListener('message', e => { if (e.data === 'ready') window.frameReady = true; });</script>
                <iframe onload="window.frameLoads++" src='\(frameURL.absoluteString)'></iframe>
                """),
        ])
        let file = URL.temporaryDirectory.appending(path: "StaleWebKitFrame-\(UUID().uuidString).json")
        let store = SitePermissions(storageURL: file)
        let tab = BrowserTab(opensBlank: false, sitePermissions: store)
        var resolverContinuation: CheckedContinuation<ExternalApp.Match?, Never>?
        var presenterContinuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
        var resolverEntered = false
        var resolverFinished = false
        var presenterEntered = false
        var presenterFinished = false
        var prompts = 0
        var opened: [URL] = []
        ExternalApp.resolverForTesting = { _ in
            resolverEntered = true
            guard !suspendedAtPresenter else {
                return .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier)
            }
            let match = await withCheckedContinuation { resolverContinuation = $0 }
            resolverFinished = true
            return match
        }
        ExternalApp.presenterForTesting = { alert in
            prompts += 1
            alert.suppressionButton?.state = .on
            presenterEntered = true
            let response = await withCheckedContinuation { presenterContinuation = $0 }
            presenterFinished = true
            return response
        }
        ExternalApp.openerForTesting = { opened.append($0) }
        defer {
            tab.detach()
            resolverContinuation?.resume(returning: nil)
            presenterContinuation?.resume(returning: .alertSecondButtonReturn)
            ExternalApp.resolverForTesting = nil
            ExternalApp.presenterForTesting = nil
            ExternalApp.openerForTesting = nil
            try? FileManager.default.removeItem(at: file)
            withExtendedLifetime((frameServer, topServer)) {}
        }

        let topURL = try topServer.url()
        tab.load(topURL)
        try #require(await settled(tab, at: topURL))
        try #require(await waitUntil { (try? await tab.page.evaluateJavaScript("window.frameReady === true")) as? Bool == true })
        _ = try await tab.page.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage('go', '*'); true")
        if suspendedAtPresenter {
            try #require(await waitUntil { presenterEntered })
        } else {
            try #require(await waitUntil { resolverEntered })
        }
        _ = try await tab.page.evaluateJavaScript(mutation.script)
        try #require(await waitUntil {
            (try? await tab.page.evaluateJavaScript(mutation.settledScript)) as? Bool == true
        })
        if suspendedAtPresenter {
            presenterContinuation?.resume(returning: .alertFirstButtonReturn)
            presenterContinuation = nil
            try #require(await waitUntil { presenterFinished })
        } else {
            resolverContinuation?.resume(returning: .init(
                url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier
            ))
            resolverContinuation = nil
            try #require(await waitUntil { resolverFinished })
        }
        try #require(await waitUntil { !ExternalApp.hasPendingOfferForTesting })
        #expect(prompts == (suspendedAtPresenter ? 1 : 0))
        #expect(opened.isEmpty)
        #expect(store.externalAppRecords.isEmpty)
        #expect(!tab.externalApps.allows(app, from: SitePermissions.origin(for: frameURL)))
        await store.waitForPendingSave()
        #expect(SitePermissions(storageURL: file).externalAppRecords.isEmpty)
    }
    @Test(arguments: FrameMutation.allCases, [false, true])
    private func staleTopTargetedCEFHandoffCannotLaunchAfterResolverSuspends(
        _ mutation: FrameMutation, noReferrer: Bool
    ) async throws {
        try await staleTopTargetedCEFHandoff(mutation, suspendedAtPresenter: false, noReferrer: noReferrer)
    }

    @Test(arguments: FrameMutation.allCases, [false, true])
    private func staleTopTargetedCEFHandoffCannotRememberAfterPresenterSuspends(
        _ mutation: FrameMutation, noReferrer: Bool
    ) async throws {
        try await staleTopTargetedCEFHandoff(mutation, suspendedAtPresenter: true, noReferrer: noReferrer)
    }

    private func staleTopTargetedCEFHandoff(
        _ mutation: FrameMutation,
        suspendedAtPresenter: Bool,
        noReferrer: Bool
    ) async throws {
        let app = ExternalAppPermission(scheme: "slack", bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        let externalURL = URL(string: "slack://open")!
        let frameServer = try await HTTPFixtureServer.start(routes: [
            "/frame": .html("""
                \(noReferrer ? "<meta name='referrer' content='no-referrer'>" : "")
                <script>
                addEventListener('message', e => {
                  if (e.data === 'go') top.location.href = '\(externalURL.absoluteString)';
                });
                parent.postMessage('ready', '*');
                </script>
                """),
            "/replacement": .html("<title>Replacement</title>"),
        ])
        let frameURL = try frameServer.url("/frame")
        let topServer = try await HTTPFixtureServer.start(routes: [
            "/page": .html("""
                <script>window.frameLoads = 0; addEventListener('message', e => { if (e.data === 'ready') window.frameReady = true; });</script>
                <iframe onload="window.frameLoads++" src='\(frameURL.absoluteString)'></iframe>
                """),
        ])
        let topURL = try topServer.url("/page")
        let file = URL.temporaryDirectory.appending(path: "StaleCEFFrame-\(UUID().uuidString).json")
        let store = SitePermissions(storageURL: file)
        store.setEngine(.chromium, for: SitePermissions.origin(for: topURL))
        let tab = BrowserTab(opensBlank: false, sitePermissions: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        var resolverContinuation: CheckedContinuation<ExternalApp.Match?, Never>?
        var presenterContinuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
        var resolverEntered = false
        var resolverFinished = false
        var presenterEntered = false
        var presenterFinished = false
        var prompts = 0
        var opened: [URL] = []
        ExternalApp.resolverForTesting = { _ in
            resolverEntered = true
            guard !suspendedAtPresenter else {
                return .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier)
            }
            let match = await withCheckedContinuation { resolverContinuation = $0 }
            resolverFinished = true
            return match
        }
        ExternalApp.presenterForTesting = { alert in
            prompts += 1
            alert.suppressionButton?.state = .on
            presenterEntered = true
            let response = await withCheckedContinuation { presenterContinuation = $0 }
            presenterFinished = true
            return response
        }
        ExternalApp.openerForTesting = { opened.append($0) }
        defer {
            tab.detach()
            resolverContinuation?.resume(returning: nil)
            presenterContinuation?.resume(returning: .alertSecondButtonReturn)
            window.close()
            ExternalApp.resolverForTesting = nil
            ExternalApp.presenterForTesting = nil
            ExternalApp.openerForTesting = nil
            try? FileManager.default.removeItem(at: file)
            withExtendedLifetime((frameServer, topServer)) {}
        }

        tab.load(topURL)
        window.contentView = tab.page
        try #require(await settled(tab, at: topURL))
        try #require(tab.page.engine == .chromium)
        try #require(await waitUntil { (try? await tab.page.evaluateJavaScript("window.frameReady === true")) as? Bool == true })
        let chromium = try #require(tab.page.chromium)
        let frames = try await chromium.devTools.frames()
        let sourceFrame = try #require(frames.first { $0.request.url == frameURL })
        _ = try await chromium.devTools.evaluate("window.postMessage('go', '*'); true", in: sourceFrame, world: .page)
        if suspendedAtPresenter {
            try #require(await waitUntil { presenterEntered })
        } else {
            try #require(await waitUntil { resolverEntered })
        }
        _ = try await chromium.devTools.evaluate(mutation.script, in: nil, world: .page)
        try #require(await waitUntil {
            (try? await chromium.devTools.evaluate(mutation.settledScript, in: nil, world: .page)) as? Bool == true
        })
        if suspendedAtPresenter {
            presenterContinuation?.resume(returning: .alertFirstButtonReturn)
            presenterContinuation = nil
            try #require(await waitUntil { presenterFinished })
        } else {
            resolverContinuation?.resume(returning: .init(
                url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier
            ))
            resolverContinuation = nil
            try #require(await waitUntil { resolverFinished })
        }
        try #require(await waitUntil { !ExternalApp.hasPendingOfferForTesting })
        #expect(prompts == (suspendedAtPresenter ? 1 : 0))
        #expect(opened.isEmpty)
        #expect(store.externalAppRecords.isEmpty)
        #expect(!tab.externalApps.allows(app, from: SitePermissions.origin(for: frameURL)))
        await store.waitForPendingSave()
        #expect(SitePermissions(storageURL: file).externalAppRecords.isEmpty)
    }

    private func activateOpaqueFrameLink(in tab: BrowserTab) async throws {
        _ = try await tab.page.evaluateJavaScript("window.opaqueFrameActivated = window.opaqueFrameFocused = false; true")
        let window = try #require(tab.page.window)
        try #require(window.makeFirstResponder(tab.page))
        _ = try await tab.page.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage('focus', '*'); true")
        try #require(await waitUntil {
            (try? await tab.page.evaluateJavaScript("window.opaqueFrameFocused")) as? Bool == true
        })
        // Native keyboard activation does not depend on background-window compositor hit testing.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
            tab.page.sendKeyEvent(event)
        }
        try #require(await waitUntil {
            (try? await tab.page.evaluateJavaScript("window.opaqueFrameActivated")) as? Bool == true
        })
    }

}
