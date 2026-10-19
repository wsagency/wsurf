// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The password client's field tracker, in both engines, read from what the shipped script posts: what it sends again after a vault
/// was unlocked, and which lone field of an identifier-first step it takes for the login's username. No native dropdown is involved.
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

        /// The field's kind and category as the shared form model gives them, `kind/category`.
        func classification(_ id: String) async throws -> String? {
            try await run(
                "const f = globalThis.__wsurfAutofillForms.field(document.getElementById(id)); return `${f?.kind ?? null}/${f?.category ?? null}`;",
                ["id": id]
            ) as? String
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

    /// The selection of a field whose autocomplete includes `webauthn` says so, which is what lets native add "Use a Passkey…" there.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aWebAuthnFieldIsReportedAsOneAndAPlainUsernameFieldIsNot(engine: BrowserEngine) async throws {
        let html = """
            <form><input id="passkey" autocomplete="username webauthn"><button>Next</button></form>
            <form><input id="plain" autocomplete="username"><input type="password"><button>Go</button></form>
            """
        try await withHarness(engine, html) { harness in
            for (id, expected) in [("passkey", true), ("plain", false)] {
                let count = harness.selections.count
                try await harness.run("document.getElementById(id).focus(); globalThis.__wsurfPasswords.refresh();", ["id": id])
                try #require(await waitUntil { harness.selections.count > count }, "\(id) is offered on \(engine)")
                let selection = try #require(harness.selections.last)
                #expect(selection["kind"] as? String == "username", "\(id) on \(engine)")
                #expect(selection["webauthn"] as? Bool == expected, "\(id) on \(engine)")
            }
        }
    }

    // MARK: Identifier-first steps

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aLoneEmailOrUserIDStepIsTheLoginsUsername(engine: BrowserEngine) async throws {
        let html = """
            <form><input id="email" type="email" name="email"><button>Next</button></form>
            <form><input id="userid" type="text" name="userId"><input id="remember" type="checkbox"><button>Continue</button></form>
            <form><input id="identifier" type="text" name="identifier" autocomplete="off"><button>Next</button></form>
            """
        try await withHarness(engine, html) { harness in
            for id in ["email", "userid", "identifier"] {
                #expect(try await harness.classification(id) == "username/password", "\(id) on \(engine)")
            }
            try await harness.run("document.getElementById('email').focus(); globalThis.__wsurfPasswords.refresh();")
            try #require(await waitUntil { harness.selections.contains { $0["kind"] as? String == "username" } }, "offered on \(engine)")
            let selection = try #require(harness.selections.last { $0["kind"] as? String == "username" })
            #expect(selection["field"] as? String == "password")
            let filled = try await harness.run(
                "return globalThis.__wsurfPasswords.fill(token, url, {username: 'ada@example.test', password: 'dummy-secret'});",
                ["token": selection["token"] as? String ?? "", "url": selection["url"] as? String ?? ""]
            )
            #expect(filled as? Int == 1, "only the account is filled on \(engine)")
            #expect(try await harness.run("return document.getElementById('email').value;") as? String == "ada@example.test")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func otherLoneFieldsKeepTheirMeaning(engine: BrowserEngine) async throws {
        let html = """
            <form><input id="declared" type="email" autocomplete="email"><button>Next</button></form>
            <form><input id="news" type="email" placeholder="Subscribe to our newsletter"><button>Go</button></form>
            <form><input id="mail" type="email"><input id="name" autocomplete="name"><button>Send</button></form>
            <form><input id="query" type="text" name="q"><button>Find</button></form>
            <form><input id="code" type="text" autocomplete="one-time-code"><button>Verify</button></form>
            """
        try await withHarness(engine, html) { harness in
            let declared = try await harness.classification("declared")
            let news = try await harness.classification("news")
            let mail = try await harness.classification("mail")
            let query = try await harness.classification("query")
            let code = try await harness.classification("code")
            #expect(declared == "email/contact", "a declared purpose wins on \(engine)")
            #expect(news == "email/contact", "newsletter wording on \(engine)")
            #expect(mail == "email/contact", "not alone in its group on \(engine)")
            #expect(query == "null/null", "no account wording on \(engine)")
            #expect(code == "one-time-code/null", "a verification code on \(engine)")
        }
    }
}
