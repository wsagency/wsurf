// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The password client's field tracker, in both engines, read from what the shipped script posts: what it sends again after a vault
/// was unlocked. No native dropdown is involved.
@MainActor
struct PasswordAutofillTrackerTests {
    /// Everything the script posts, in order.
    private final class Harness {
        let page: BrowserPage
        private(set) var posts: [[String: Any]] = []

        init(page: BrowserPage) {
            self.page = page
        }

        func receive(_ body: Any) {
            guard let post = body as? [String: Any] else { return }
            posts.append(post)
        }

        var selections: [[String: Any]] {
            posts.filter { $0["action"] as? String == "select" }
        }

        /// Runs in the script's own world, the one the page cannot reach.
        @discardableResult
        func run(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any {
            try await page.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: PasswordAutofill.world)
        }

        /// Waits until everything posted so far has arrived, so that "nothing was selected" can be asserted.
        func settle() async throws {
            let marker = UUID().uuidString
            try await run("globalThis.__wsurfSend('wsurfPasswords', {action: 'ping', marker});", ["marker": marker])
            #expect(await waitUntil { self.posts.contains { $0["marker"] as? String == marker } })
        }
    }

    private func withHarness(_ engine: BrowserEngine, _ html: String, body: (Harness) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><html><body>\(html)</body></html>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration),
                context: context
            )
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            page = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        let harness = Harness(page: page)
        page.installScript(PasswordAutofillScript.source, in: PasswordAutofill.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: "wsurfPasswords", in: PasswordAutofill.world) { harness.receive($0.body) }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try #require(await waitUntil { harness.posts.contains { $0["action"] as? String == "ready" } })
            try await harness.run("globalThis.__wsurfPasswords.setEnabled(true);")
            try await body(harness)
        } catch {
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        await page.close()
        await context.endPrivateSession()
    }

    private static let login = #"<form><input id="u" autocomplete="username"><input id="p" type="password"></form><button id="b">Go</button>"#

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func anUnlockSelectsTheStillFocusedFieldAgainWithItsToken(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.login) { harness in
            try await harness.run("document.getElementById('p').focus(); globalThis.__wsurfPasswords.refresh();")
            try #require(await waitUntil { !harness.selections.isEmpty }, "the focused field is selected on \(engine)")
            let first = try #require(harness.selections.last)
            let token = try #require(first["token"] as? String)
            try await harness.settle()
            let count = harness.selections.count

            try await harness.run("globalThis.__wsurfPasswords.refresh();")

            #expect(await waitUntil { harness.selections.count > count }, "an unlock selects the field again on \(engine)")
            #expect(harness.selections.last?["token"] as? String == token, "the same field keeps its token")
            #expect(harness.selections.last?["fieldID"] as? String == first["fieldID"] as? String)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func anUnlockSelectsNothingWithoutAFocusedLoginFieldOrWhileFillingIsOff(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.login) { harness in
            try await harness.run("document.getElementById('b').focus(); globalThis.__wsurfPasswords.refresh();")
            try await harness.settle()
            #expect(harness.selections.isEmpty, "a button is not a login field")

            try await harness.run("""
                document.getElementById('p').focus();
                globalThis.__wsurfPasswords.setEnabled(false);
                globalThis.__wsurfPasswords.refresh();
                await new Promise(resolve => setTimeout(resolve, 1200));
                """)
            try await harness.settle()
            #expect(harness.selections.isEmpty, "a profile with filling off is never offered anything on \(engine)")
        }
    }
}
