// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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

    /// A page that answers 401 until the request carries `user` and `password`.
    private func server(user: String, password: String) async throws -> HTTPFixtureServer {
        let expected = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        return try await HTTPFixtureServer.start(routes: [:], respond: { request in
            guard request.path == "/" else { return nil }
            if request.headers["authorization"] == expected {
                return .html("<!doctype html><title>Signed in</title><p>Welcome</p>")
            }
            return HTTPFixtureServer.Response(
                status: "401 Unauthorized",
                headers: ["WWW-Authenticate": "Basic realm=\"Staff\"", "Content-Type": "text/html; charset=utf-8"],
                body: Data("<!doctype html><title>Unauthorized</title><p>No</p>".utf8))
        })
    }

    private func title(of tab: BrowserTab) async -> String? {
        try? await tab.page.evaluateJavaScript("document.title") as? String
    }

    /// Loads the fixture in `engine` with `answers` giving the credential for each ask (nil cancels). Returns the failure counts
    /// the sheet was asked with and the page's title once it settles.
    private func signIn(
        engine: BrowserEngine, server: HTTPFixtureServer, expecting title: String,
        answers: @escaping (Int) -> URLCredential?
    ) async throws -> [Int] {
        let rig = makeRig()
        defer { ProfileSettingsStore.forget(rig.profile.id) }
        var asked: [Int] = []
        AuthChallenge.credentialForTesting = { space, failures in
            #expect(space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic)
            #expect(space.realm == "Staff")
            asked.append(failures)
            return answers(failures)
        }
        defer { AuthChallenge.credentialForTesting = nil }

        let url = try server.url()
        rig.permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let tab = rig.browser.newTab(url: url)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        #expect(await waitUntil { await self.title(of: tab) == title && !tab.page.isLoading }, "the page titled \(title) loaded")
        #expect(tab.page.engine == engine)
        return asked
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
}
