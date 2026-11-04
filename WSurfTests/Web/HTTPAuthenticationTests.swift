// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import ObjectiveC
import Testing
import WebKit

@testable import WSurf

/// HTTP sign-in on both engines, against a loopback server that asks for Basic credentials. The credentials are made here and
/// answer the sign-in sheet through `AuthChallenge.credentialForTesting`; no sheet is shown and nothing real is read.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct HTTPAuthenticationTests {
    /// The SDK renames the async form of the challenge method (`webView(_:respondTo:)`), and a method with the old Swift name
    /// matches no requirement: WebKit, which asks the object whether it answers the Objective-C selector, rejects every
    /// challenge and shows the server's 401 page. The selector is spelled out because it is the contract with WebKit.
    @Test func theNavigationDelegateAnswersWebKitsAuthenticationChallenge() {
        let selector = NSSelectorFromString("webView:didReceiveAuthenticationChallenge:completionHandler:")
        #expect(TabNavigationDelegate.instancesRespond(to: selector))
        #expect(protocol_getMethodDescription(WKNavigationDelegate.self, selector, false, true).name == selector,
                "WebKit still has that method")
    }

    private struct Rig {
        let browser: BrowserModel
        let permissions: SitePermissions
        let profile: Profile
    }

    private func makeRig() -> Rig {
        let profile = Profile(id: UUID(), name: "HTTP sign-in fixture", symbol: "lock", color: .teal)
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("HTTPAuth-\(UUID().uuidString).json"))
        let browser = BrowserModel(
            context: BrowserProfileContext(profile: profile), windowID: UUID(), database: .temporary(), sitePermissions: permissions)
        return Rig(browser: browser, permissions: permissions, profile: profile)
    }

    /// A site that answers 401 until the request carries `user` and `password`. `open` paths answer 200 whatever the request carries,
    /// and `pages` are other fixed answers; the realm is worded the way a phishing site would word it when `realm` says so.
    private func server(
        user: String, password: String, realm: String = "Staff", pages: [String: HTTPFixtureServer.Response] = [:],
        protected paths: Set<String> = ["/"]
    ) async throws -> HTTPFixtureServer {
        let expected = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        return try await HTTPFixtureServer.start(routes: pages, respond: { request in
            guard paths.contains(request.path) || paths.contains("*") else { return nil }
            if request.headers["authorization"] == expected {
                return .html("<!doctype html><title>Signed in</title><p>Welcome</p>")
            }
            return HTTPFixtureServer.Response(
                status: "401 Unauthorized",
                headers: ["WWW-Authenticate": "Basic realm=\"\(realm)\"", "Content-Type": "text/html; charset=utf-8"],
                body: Data("<!doctype html><title>Unauthorized</title><p>No</p>".utf8))
        })
    }

    private func title(of tab: BrowserTab) async -> String? {
        try? await tab.page.evaluateJavaScript("document.title") as? String
    }

    private struct Asked {
        var failures: [Int] = []
        var origins: [String] = []
    }

    /// Opens `start` in `engine` (then `next`, as a navigation of the same tab) with `answers` giving the credential for each ask
    /// (nil cancels), and returns what the sheet was asked once the page's title is `title`.
    private func visit(
        engine: BrowserEngine, start: URL, next: URL? = nil, alsoOn others: [URL] = [], expecting title: String,
        act: ((BrowserTab) async throws -> Void)? = nil, answers: @escaping (Int) -> URLCredential?
    ) async throws -> Asked {
        let rig = makeRig()
        defer { ProfileSettingsStore.forget(rig.profile.id) }
        var asked = Asked()
        AuthChallenge.credentialForTesting = { space, failures in
            asked.failures.append(failures)
            asked.origins.append(AuthChallenge.askingOrigin(of: space))
            return answers(failures)
        }
        defer { AuthChallenge.credentialForTesting = nil }

        for url in [start, next].compactMap({ $0 }) + others {
            rig.permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        }
        let tab = rig.browser.newTab(url: start)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        if let next {
            try #require(await waitUntil { tab.page.url == start && !tab.page.isLoading && tab.page.mainDocumentID != nil })
            tab.page.load(URLRequest(url: next))
        }
        if let act {
            try #require(await waitUntil { tab.page.url == start && !tab.page.isLoading && tab.page.mainDocumentID != nil })
            try await act(tab)
        }
        #expect(await waitUntil { await self.title(of: tab) == title && !tab.page.isLoading }, "the page titled \(title) loaded")
        #expect(tab.page.engine == engine)
        return asked
    }

    private func signIn(
        engine: BrowserEngine, server: HTTPFixtureServer, expecting title: String, answers: @escaping (Int) -> URLCredential?
    ) async throws -> [Int] {
        let asked = try await visit(engine: engine, start: try server.url(), expecting: title, answers: answers)
        #expect(Set(asked.origins) == [try #require(AuthChallenge.origin(of: try server.url()))], "the sheet names the website that asks")
        return asked.failures
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aPasswordPageOpensWithTheCredentialTheSheetGave(engine: BrowserEngine) async throws {
        let user = "wsurf-test-user"
        let password = UUID().uuidString
        let server = try await server(user: user, password: password)
        let asked = try await signIn(engine: engine, server: server, expecting: "Signed in") { _ in
            URLCredential(user: user, password: password, persistence: .forSession)
        }
        #expect(asked == [0], "one sheet, with no refused password before it")
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aRefusedPasswordAsksAgainAndSaysSo(engine: BrowserEngine) async throws {
        let user = "wsurf-test-user"
        let password = UUID().uuidString
        let server = try await server(user: user, password: password)
        let asked = try await signIn(engine: engine, server: server, expecting: "Signed in") { failures in
            URLCredential(user: user, password: failures == 0 ? UUID().uuidString : password, persistence: .forSession)
        }
        #expect(asked == [0, 1], "the second sheet knows the first password was refused")
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func cancellingTheSheetLeavesTheServersAnswer(engine: BrowserEngine) async throws {
        let server = try await server(user: "wsurf-test-user", password: UUID().uuidString)
        let asked = try await signIn(engine: engine, server: server, expecting: "Unauthorized") { _ in nil }
        #expect(asked == [0], "cancelling is not asked about again")
    }

    // MARK: Whose sheet it is

    /// Another website's image and frame answer 401 with a realm worded like the page's own. A sheet over the page would take
    /// the page's password for them, so they are turned away without one.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func anotherWebsitesImageOrFrameNeverRaisesASheet(engine: BrowserEngine) async throws {
        let other = try await server(user: "x", password: UUID().uuidString, realm: "example.com – session expired", protected: ["*"])
        let page = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <!doctype html><title>pending</title>
                <img src="\(try other.url("/pixel.png"))" onerror="done()" onload="done()">
                <iframe src="\(try other.url("/frame"))" onload="done()"></iframe>
                <script>var n = 0; function done() { if (++n == 2) document.title = 'settled' }</script>
                """),
        ])
        let asked = try await visit(engine: engine, start: try page.url(), expecting: "settled") { _ in
            Issue.record("a sheet was raised for another website")
            return nil
        }
        #expect(asked.failures.isEmpty)
        #expect(other.lastRequestHead(for: "/pixel.png") != nil, "the other website was asked, so the refusal is the browser's")
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func theSameWebsitesImageStillAsks(engine: BrowserEngine) async throws {
        let user = "wsurf-test-user"
        let password = UUID().uuidString
        let server = try await server(
            user: user, password: password,
            pages: [
                "/": .html("""
                <!doctype html><title>pending</title>
                <img src="/private.png" onerror="document.title = 'settled'" onload="document.title = 'settled'">
                """),
            ],
            protected: ["/private.png"]
        )
        let asked = try await visit(engine: engine, start: try server.url(), expecting: "settled") { _ in
            URLCredential(user: user, password: password, persistence: .forSession)
        }
        #expect(asked.failures == [0])
        #expect(server.lastRequestHead(for: "/private.png")?.lowercased().contains("authorization: basic") == true, "the answer went with the request")
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aMainFrameNavigationToAnotherWebsiteAsksAndNamesIt(engine: BrowserEngine) async throws {
        let user = "wsurf-test-user"
        let password = UUID().uuidString
        let target = try await server(user: user, password: password)
        let start = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Start</title>")])
        let asked = try await visit(engine: engine, start: try start.url(), next: try target.url(), expecting: "Signed in") { _ in
            URLCredential(user: user, password: password, persistence: .forSession)
        }
        #expect(asked.failures == [0])
        #expect(asked.origins == [try #require(AuthChallenge.origin(of: try target.url()))])
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aRedirectToAnotherWebsiteThatAsksIsStillTheMainFrame(engine: BrowserEngine) async throws {
        let user = "wsurf-test-user"
        let password = UUID().uuidString
        let target = try await server(user: user, password: password)
        let start = try await HTTPFixtureServer.start(routes: ["/": .redirect(to: try target.url())])
        let asked = try await visit(engine: engine, start: try start.url(), alsoOn: [try target.url()], expecting: "Signed in") { _ in
            URLCredential(user: user, password: password, persistence: .forSession)
        }
        #expect(asked.failures == [0])
    }

    // MARK: A navigation that ended without a page

    private static let loadOtherWebsitesImage = "var i = new Image(); i.onload = i.onerror = function () { document.title = 'settled' }; i.src = '%@'"

    /// The page's own address is the only one that counts once a navigation to another website ended without becoming the page:
    /// stopped, answered with no content, or failed. An old request must not lend that website a sheet over this page.
    private func afterAnEndedNavigation(
        engine: BrowserEngine, end: @escaping (BrowserTab, HTTPFixtureServer, ResponseGate) async throws -> Void
    ) async throws {
        let gate = ResponseGate()
        let other = try await server(
            user: "x", password: UUID().uuidString, realm: "example.com – session expired",
            pages: [
                "/slow": .html("<!doctype html><title>Slow</title>", gate: gate),
                "/empty": HTTPFixtureServer.Response(status: "204 No Content", headers: [:], body: Data()),
            ],
            protected: ["/pixel.png"]
        )
        let page = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Start</title>")])
        let image = try other.url("/pixel.png").absoluteString
        let asked = try await visit(
            engine: engine, start: try page.url(), alsoOn: [try other.url()], expecting: "settled",
            act: { tab in
                try await end(tab, other, gate)
                _ = try await tab.page.evaluateJavaScript(String(format: Self.loadOtherWebsitesImage, image))
            },
            answers: { _ in
                Issue.record("a sheet was raised for a navigation that never became the page")
                return nil
            }
        )
        #expect(asked.failures.isEmpty)
        #expect(other.lastRequestHead(for: "/pixel.png") != nil, "the other website was asked, so the refusal is the browser's")
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aStoppedNavigationLendsItsWebsiteNoSheet(engine: BrowserEngine) async throws {
        try await afterAnEndedNavigation(engine: engine) { tab, other, gate in
            tab.page.load(URLRequest(url: try other.url("/slow")))
            try #require(await gate.waitForRequest(), "the other website was asked for the page")
            tab.page.stopLoading()
            try #require(await waitUntil { !tab.page.isLoading })
            gate.open()
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aNavigationAnsweredWithNoContentLendsItsWebsiteNoSheet(engine: BrowserEngine) async throws {
        try await afterAnEndedNavigation(engine: engine) { tab, other, _ in
            tab.page.load(URLRequest(url: try other.url("/empty")))
            try #require(await waitUntil { other.lastRequestHead(for: "/empty") != nil && !tab.page.isLoading })
        }
    }
}
