// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The password client's field tracker, in both engines, read from what the shipped script posts: what it sends again after a vault
/// was unlocked, which lone field of an identifier-first step it takes for the login's username, and what a fill it took leaves for
/// the native request check. No native dropdown is involved.
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

        /// Focuses the field `id` and returns the `select` the script then posts for it.
        func select(_ id: String) async throws -> [String: Any] {
            let count = selections.count
            try await run("document.getElementById(id).focus(); globalThis.__wsurfPasswords.refresh();", ["id": id])
            try #require(await waitUntil { self.selections.count > count }, "\(id) is selected")
            return try #require(selections.last)
        }

        private func request(_ selection: [String: Any]) -> [String: Any] {
            ["token", "url", "documentID", "formID", "fieldID"].reduce(into: [:]) { $0[$1] = selection[$1] as? String ?? "" }
        }

        /// Whether the page still answers the request check `AutofillSuggestions.validate` makes before a fill: the selected field's
        /// geometry while the request's token is the page's, otherwise nothing.
        func validates(_ selection: [String: Any]) async throws -> Bool {
            try await run("""
                const model = globalThis.__wsurfAutofillForms;
                const active = globalThis.__wsurfAutofillSuggestions?.active();
                if (model?.documentID !== documentID || !active || model.id(active) !== fieldID || model.group(active)?.id !== formID) return null;
                return globalThis.__wsurfPasswords?.bounds(token, url) ?? null;
                """, request(selection)) is [String: Any]
        }

        /// Fills through the transport and call `AutofillSuggestions.fill` uses, and returns the page's answer as it reads it.
        func fill(_ selection: [String: Any], username: String, password: String) async throws -> Int {
            var arguments = request(selection)
            arguments["bridge"] = "__wsurfPasswords"
            arguments["fields"] = ["username": username, "password": password]
            nonisolated(unsafe) let values = arguments
            let answer = try await page.callAsyncJavaScript(
                "if (globalThis.__wsurfAutofillForms?.documentID !== documentID) return 0; return globalThis[bridge]?.fill(token, url, fields) || 0;",
                in: nil, contentWorld: PasswordAutofill.world, prepareArguments: { values }
            )
            return answer as? Int ?? 0
        }

        func value(_ id: String) async throws -> String? {
            try await run("return document.getElementById(id).value;", ["id": id]) as? String
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

    // MARK: A fill the page took

    // The page spends a field's token on the fill it takes, so the request check made before a fill no longer finds the request
    // afterwards. Making that check again after delivery reported every delivered fill as "Couldn’t Fill Saved Details" and skipped
    // recording the pick; the page's answer alone decides now.

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aDeliveredFillSpendsTheTokenTheRequestCheckAsksAbout(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.login) { harness in
            let selection = try await harness.select("p")
            #expect(try await harness.validates(selection), "the request is current before the fill on \(engine)")

            #expect(try await harness.fill(selection, username: "ada@example.test", password: "dummy-secret") == 2, "delivered on \(engine)")

            #expect(try await harness.value("u") == "ada@example.test")
            #expect(try await harness.value("p") == "dummy-secret")
            #expect(try await harness.validates(selection) == false, "the page spent the token on \(engine)")
            #expect(try await harness.fill(selection, username: "ada@example.test", password: "dummy-secret") == 0, "and fills once")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func bothStepsOfAnIdentifierFirstLoginAreDelivered(engine: BrowserEngine) async throws {
        let html = """
            <form id="login"><input id="email" type="email" name="email"><button id="next" type="button">Next</button></form>
            <script>
              document.getElementById('next').onclick = () => {
                document.getElementById('login').innerHTML = '<input id="p" type="password" autocomplete="current-password">';
              };
            </script>
            """
        try await withHarness(engine, html) { harness in
            let account = try await harness.select("email")
            #expect(try await harness.fill(account, username: "ada@example.test", password: "dummy-secret") == 1, "the account step on \(engine)")
            #expect(try await harness.value("email") == "ada@example.test")
            #expect(try await harness.validates(account) == false)

            try await harness.run("document.getElementById('next').click();")
            let password = try await harness.select("p")
            #expect(password["token"] as? String != account["token"] as? String)
            #expect(try await harness.fill(password, username: "ada@example.test", password: "dummy-secret") == 1, "the password step on \(engine)")
            #expect(try await harness.value("p") == "dummy-secret")
            #expect(try await harness.validates(password) == false)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aFillIsDeliveredWhenThePageReformatsTheValue(engine: BrowserEngine) async throws {
        let html = Self.login + """
            <script>
              document.getElementById('u').addEventListener('input', event => {
                event.target.value = event.target.value.trim().toLowerCase();
              });
            </script>
            """
        try await withHarness(engine, html) { harness in
            let selection = try await harness.select("p")
            #expect(try await harness.fill(selection, username: " Ada@Example.TEST ", password: "dummy-secret") == 2, "delivered on \(engine)")
            #expect(try await harness.value("u") == "ada@example.test", "the page's own format on \(engine)")
            #expect(try await harness.value("p") == "dummy-secret")
            #expect(try await harness.validates(selection) == false)
        }
    }
}
