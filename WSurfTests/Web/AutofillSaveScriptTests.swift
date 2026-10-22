// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The page script that watches a login form and stages a save offer. A test process gets hooks that call its real
/// handlers with events marked trusted (an engine cannot be made to produce them), so every behavior below runs the
/// shipped code, in both engines, and is read from what the script posts.
@MainActor
struct AutofillSaveScriptTests {
    private static let account = "ada@example.test"
    private static let secret = "dummy-secret-123"
    private static let credentials = #"<input id="u" autocomplete="username"><input id="p" type="password" autocomplete="current-password">"#
    private static let button = #"<button id="go" type="button">Sign in</button>"#

    private static func form(_ fields: String = Self.credentials, _ control: String = Self.button, attributes: String = "") -> String {
        #"<form id="form" onsubmit="return false" \#(attributes)>\#(fields)\#(control)</form>"#
    }

    /// Everything the script posts, in order, and the ways a test acts on the page.
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

        func posted(_ action: String) -> [[String: Any]] { posts.filter { $0["action"] as? String == action } }

        var staged: [[String: Any]] { posted("stage") }
        var login: [String: String]? { staged.first?["password"] as? [String: String] }

        /// Runs in the script's own world, the one the page cannot reach.
        func run(_ body: String, _ arguments: [String: Any] = [:]) async throws {
            _ = try await page.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: AutofillPage.world)
        }

        /// A person typing: the value changes and a trusted `input` event reaches the real handler.
        func type(_ id: String, _ value: String) async throws {
            try await run(
                "const e = document.getElementById(id); e.value = value; globalThis.__wsurfAutofillSave.__test.edit(e);",
                ["id": id, "value": value]
            )
        }

        /// An extension or the page filling a field: the value changes and nothing else happens.
        func fill(_ id: String, _ value: String) async throws {
            try await run("document.getElementById(id).value = value;", ["id": id, "value": value])
        }

        /// A trusted `click`, `enter`, or `submit` on the element.
        func hook(_ name: String, _ id: String) async throws {
            try await run("globalThis.__wsurfAutofillSave.__test[name](document.getElementById(id));", ["name": name, "id": id])
        }

        /// What the fill and capture paths ask: the shared `safe(form)` and the group's cached answer.
        func safety(of id: String) async throws -> String {
            let result = try await page.callAsyncJavaScript(
                "const f = globalThis.__wsurfAutofillForms, e = document.getElementById(id); return [f.safe(e), f.group(e).safe].join();",
                arguments: ["id": id], in: nil, contentWorld: AutofillPage.world
            )
            return try #require(result as? String)
        }

        /// The script's `check` does nothing in a hidden document (a background tab neither completes nor expires an attempt),
        /// and the engine hides a document whose window another window covers. So it runs only once the document is visible;
        /// otherwise the window's state is reported here instead of as a 25 s wait for a post that cannot come.
        func check() async throws {
            let shown = await waitUntil { (try? await self.page.evaluateJavaScript("document.visibilityState")) as? String == "visible" }
            let window = page.window
            try #require(shown, """
                The document is hidden: window.isVisible=\(window?.isVisible == true), \
                occluded=\(window.map { !$0.occlusionState.contains(.visible) } ?? true), app.isActive=\(NSApp.isActive)
                """)
            try await run("globalThis.__wsurfAutofillSave.check();")
        }

        func age(_ milliseconds: Int) async throws {
            try await run("globalThis.__wsurfAutofillSave.__test.age(milliseconds);", ["milliseconds": milliseconds])
        }

        /// Waits until everything posted so far has arrived, so that "nothing was staged" can be asserted.
        func settle() async throws {
            let marker = UUID().uuidString
            try await run("globalThis.__wsurfSend('wsurfAutofillSave', {action: 'ping', marker});", ["marker": marker])
            #expect(await waitUntil { self.posts.contains { $0["marker"] as? String == marker } })
        }
    }

    private func withHarness(
        _ engine: BrowserEngine, _ html: String, head: String = "",
        policy: [String: Bool] = ["password": true, "card": false, "contact": false],
        body: (Harness) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><html><head>\(head)</head><body>\(html)</body></html>"),
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
        // In front of every other window, the test's own only: a window ordered to the back is hidden whenever another one
        // covers it, which depends on what else is on screen at that moment.
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        let harness = Harness(page: page)
        page.installScript(AutofillSaveScript.source, in: AutofillPage.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: "wsurfAutofillSave", in: AutofillPage.world) { harness.receive($0.body) }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try #require(await waitUntil { !harness.posted("ready").isEmpty })
            try await harness.run("globalThis.__wsurfAutofillSave.setPolicy(policy);", ["policy": policy])
            try await body(harness)
        } catch {
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        await page.close()
        await context.endPrivateSession()
    }

    private func typeLogin(_ harness: Harness, user: String = Self.account, password: String = Self.secret) async throws {
        try await harness.type("u", user)
        try await harness.type("p", password)
    }

    // MARK: Login buttons that are not buttons

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases, ["#", "#top", "javascript:void(0)"])
    func linkThatStaysOnThePageIsTheLoginButton(engine: BrowserEngine, href: String) async throws {
        try await withHarness(engine, Self.form(Self.credentials, #"<a id="go" href="\#(href)">Sign in</a>"#)) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            #expect(harness.staged[0]["source"] as? String == "interaction")
            #expect(harness.login == ["username": Self.account, "password": Self.secret])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func anIdentifierFirstEmailStepStagesItsUsername(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.form(#"<input id="e" type="email" name="email">"#)) { harness in
            try await harness.type("e", Self.account)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            #expect(harness.staged[0]["username"] as? String == Self.account)
            #expect(harness.login == nil, "a username step carries no password")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func clickOnAPlainDivInsideTheFormStagesAnInteraction(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.form(Self.credentials, #"<div id="go" class="btn">Sign in</div>"#)) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            #expect(harness.login == ["username": Self.account, "password": Self.secret])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func clickIntoAFieldOrOutsideTheFormStagesNothing(engine: BrowserEngine) async throws {
        let html = #"<div id="outside">Terms of use</div>"# + Self.form(Self.credentials, #"<div id="go">Sign in</div>"#)
        try await withHarness(engine, html) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "u")
            try await harness.hook("click", "outside")
            try await harness.settle()
            #expect(harness.staged.isEmpty)
            // The same page does stage once the form itself is clicked.
            try await harness.hook("click", "go")
            #expect(await waitUntil { harness.staged.count == 1 })
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func linkToAnotherPageStillAbandons(engine: BrowserEngine) async throws {
        let html = Self.form(Self.credentials, Self.button + #"<a id="away" href="/elsewhere">Help</a>"#)
        try await withHarness(engine, html) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            try await harness.hook("click", "away")
            #expect(await waitUntil { harness.posted("discard").count == 1 })
            // Leaving the page also stops the automatic path from staging what was typed.
            try await harness.check()
            try await harness.settle()
            #expect(harness.staged.count == 1)
            #expect(harness.posted("complete").isEmpty)
        }
    }

    // MARK: Forms that submit through script

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases, ["javascript:void(0)", " JavaScript:void(0) ", "#", "#top"])
    func formWithoutARealActionIsCaptured(engine: BrowserEngine, action: String) async throws {
        try await withHarness(engine, Self.form(attributes: #"action="\#(action)""#)) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            #expect(harness.login == ["username": Self.account, "password": Self.secret])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func crossOriginActionIsStillRefused(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.form(attributes: #"action="https://other.example/post""#)) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try await harness.hook("enter", "p")
            try await harness.hook("submit", "form")
            try await harness.settle()
            #expect(harness.staged.isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aFieldNamedActionCannotHideACrossOriginAction(engine: BrowserEngine) async throws {
        let fields = Self.credentials + #"<input name="action" value="/post">"#
        try await withHarness(engine, Self.form(fields, attributes: #"action="https://other.example/post""#)) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try await harness.settle()
            #expect(harness.staged.isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases, ["action=\"#x\"", ""])
    func crossOriginBaseMakesEveryFormUnsafe(engine: BrowserEngine, attribute: String) async throws {
        let head = #"<base href="https://evil.example/">"#
        try await withHarness(engine, Self.form(attributes: attribute), head: head) { harness in
            #expect(try await harness.safety(of: "form") == "false,false")
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try await harness.hook("enter", "p")
            try await harness.settle()
            #expect(harness.staged.isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func fragmentActionIsSafeAndCapturedWhileTheBaseStaysOnTheOrigin(engine: BrowserEngine) async throws {
        let head = #"<base href="/app/">"#
        try await withHarness(engine, Self.form(attributes: ##"action="#x""##), head: head) { harness in
            #expect(try await harness.safety(of: "form") == "true,true")
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
        }
    }

    /// A login form whose submit button, inside the form or joined to it from outside, names its own destination.
    private static func submitter(_ kind: String, formaction target: String) -> String {
        switch kind {
        case "image":
            form(credentials, #"<input id="go" type="image" alt="Sign in" formaction="\#(target)">"#)
        case "outside":
            form() + #"<button id="ext" type="submit" form="form" formaction="\#(target)">Send</button>"#
        default:
            form(credentials, #"<button id="go" type="submit" formaction="\#(target)">Sign in</button>"#)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases, ["inside", "image", "outside"])
    func crossOriginFormactionMakesTheFormUnsafe(engine: BrowserEngine, kind: String) async throws {
        try await withHarness(engine, Self.submitter(kind, formaction: "https://other.example/post")) { harness in
            #expect(try await harness.safety(of: "form") == "false,false")
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try await harness.hook("enter", "p")
            try await harness.settle()
            #expect(harness.staged.isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aFieldNamedElementsCannotHideACrossOriginFormaction(engine: BrowserEngine) async throws {
        let fields = Self.credentials + #"<input name="elements" value="x"><input name="action" value="x"><input name="formaction" value="x">"#
        let control = #"<button id="go" type="submit" formaction="https://other.example/post">Sign in</button>"#
        try await withHarness(engine, Self.form(fields, control)) { harness in
            let safety = try await harness.safety(of: "form")
            #expect(safety == "false,false")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases, ["/other", "#x", "javascript:void(0)", ""])
    func formactionThatStaysOnThePageIsSafeAndCaptured(engine: BrowserEngine, target: String) async throws {
        try await withHarness(engine, Self.submitter("inside", formaction: target)) { harness in
            #expect(try await harness.safety(of: "form") == "true,true")
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
        }
    }

    // MARK: Fields that do not belong to the login

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func unrelatedInvalidFieldDoesNotBlockStaging(engine: BrowserEngine) async throws {
        let fields = Self.credentials + #"<input id="terms" name="terms" required>"#
        try await withHarness(engine, Self.form(fields)) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func invalidPasswordStillBlocksStaging(engine: BrowserEngine) async throws {
        let fields = #"<input id="u" autocomplete="username"><input id="p" type="password" pattern=".{12,}">"#
        try await withHarness(engine, Self.form(fields)) { harness in
            try await typeLogin(harness, password: "short")
            try await harness.hook("click", "go")
            #expect(await waitUntil { harness.posted("diagnostic").contains { $0["event"] as? String == "submitInvalid" } })
            #expect(harness.staged.isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func twoUsernameLikeFieldsUseTheOneBeforeThePassword(engine: BrowserEngine) async throws {
        let fields = #"<input id="phone" autocomplete="username">"# + Self.credentials
        try await withHarness(engine, Self.form(fields)) { harness in
            try await harness.type("phone", "+385991234567")
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            #expect(harness.login == ["username": Self.account, "password": Self.secret])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func unlabelledCurrentAndNewPasswordsCaptureTheNewOne(engine: BrowserEngine) async throws {
        let fields = #"<input id="u" autocomplete="username"><input id="old" type="password"><input id="fresh" type="password">"#
        try await withHarness(engine, Self.form(fields)) { harness in
            try await harness.type("u", Self.account)
            try await harness.type("old", "dummy-old-123")
            try await harness.type("fresh", "dummy-new-456")
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            #expect(harness.login == ["username": Self.account, "password": "dummy-new-456"])
        }
    }

    // MARK: No offer where there is nothing to offer

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func signupConfirmationThatDiffersStagesNothing(engine: BrowserEngine) async throws {
        let fields = #"<input id="u" autocomplete="username"><input id="first" type="password"><input id="again" type="password" placeholder="Confirm password">"#
        try await withHarness(engine, Self.form(fields)) { harness in
            try await harness.type("u", Self.account)
            try await harness.type("first", "dummy-new-456")
            try await harness.type("again", "dummy-new-465")
            try await harness.hook("click", "go")
            try await harness.hook("enter", "again")
            try await harness.settle()
            #expect(harness.staged.isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func signupConfirmationThatMatchesIsCaptured(engine: BrowserEngine) async throws {
        let fields = #"<input id="u" autocomplete="username"><input id="first" type="password"><input id="again" type="password" placeholder="Confirm password">"#
        try await withHarness(engine, Self.form(fields)) { harness in
            try await harness.type("u", Self.account)
            try await harness.type("first", "dummy-new-456")
            try await harness.type("again", "dummy-new-456")
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            #expect(harness.login == ["username": Self.account, "password": "dummy-new-456"])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func searchBoxNeverStagesAnAttempt(engine: BrowserEngine) async throws {
        let fields = #"<input id="q" type="search" name="q" placeholder="Search"><input id="t" type="text" name="query" placeholder="Search the shop">"#
        let all = ["password": true, "card": true, "contact": true]
        try await withHarness(engine, Self.form(fields, #"<div id="go">Search</div>"#, attributes: #"role="search""#), policy: all) { harness in
            try await harness.type("q", "dummy password manager")
            try await harness.type("t", Self.account)
            try await harness.hook("click", "go")
            try await harness.hook("enter", "t")
            try await harness.hook("submit", "form")
            try await harness.settle()
            #expect(harness.staged.isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func addressFormTheSitePrefilledNeverStagesOnAClick(engine: BrowserEngine) async throws {
        let fields = """
            <input id="street" autocomplete="street-address" value="1 Test Street">
            <input id="city" autocomplete="address-level2" value="Zagreb"><input id="zip" autocomplete="postal-code" value="10000">
            """
        let all = ["password": true, "card": true, "contact": true]
        try await withHarness(engine, Self.form(fields, #"<button id="go" type="button">Continue</button>"#), policy: all) { harness in
            try await harness.hook("click", "go")
            try await harness.settle()
            #expect(harness.staged.isEmpty)
        }
    }

    // MARK: Trust

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func untrustedFillThenTrustedButtonClickStages(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.form()) { harness in
            try await harness.fill("u", Self.account)
            try await harness.fill("p", Self.secret)
            try await harness.settle()
            #expect(harness.staged.isEmpty)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            #expect(harness.staged[0]["source"] as? String == "interaction")
            #expect(harness.login == ["username": Self.account, "password": Self.secret])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func scriptDispatchedEventsNeverStage(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.form()) { harness in
            try await harness.fill("u", Self.account)
            try await harness.fill("p", Self.secret)
            _ = try await harness.page.evaluateJavaScript("""
                for (const id of ['u', 'p']) document.getElementById(id).dispatchEvent(new Event('input', {bubbles: true}));
                document.getElementById('go').dispatchEvent(new MouseEvent('click', {bubbles: true}));
                document.getElementById('go').click();
                document.getElementById('form').dispatchEvent(new SubmitEvent('submit', {bubbles: true}));
                document.getElementById('p').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
                true;
                """)
            try await harness.settle()
            #expect(harness.staged.isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func pageCannotSeeTheScriptAndItLeavesOnlyTheSensitiveFieldMark(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.form()) { harness in
            let before = try #require(try await harness.page.evaluateJavaScript("document.documentElement.outerHTML") as? String)
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            let after = try #require(try await harness.page.evaluateJavaScript("document.documentElement.outerHTML") as? String)
            #expect(after.replacingOccurrences(of: #" data-wsurf-password="""#, with: "") == before)
            let visible = try await harness.page.evaluateJavaScript(
                "[typeof globalThis.__wsurfAutofillSave, typeof globalThis.__wsurfAutofillForms, typeof globalThis.__wsurfSend].join()"
            )
            #expect(visible as? String == "undefined,undefined,undefined")
        }
    }

    // MARK: How long an attempt lives

    private static let verifyingPage = #"<div id="app">"# + Self.form() + "</div>"

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func verificationStepKeepsTheRecordForFiveMinutes(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.verifyingPage) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            _ = try await harness.page.evaluateJavaScript(
                #"document.getElementById('app').innerHTML = '<input id="code" autocomplete="one-time-code">'; true;"#
            )
            try await harness.age(130_000)
            try await harness.check()
            try await harness.settle()
            #expect(harness.posted("discard").isEmpty)
            // The code is accepted and the page moves on: the attempt completes instead of having expired.
            _ = try await harness.page.evaluateJavaScript("document.getElementById('app').innerHTML = '<p>Welcome</p>'; true;")
            try await harness.check()
            try await harness.age(1000)
            try await harness.check()
            try #require(await waitUntil { harness.posted("complete").count == 1 })
            #expect(harness.posted("complete")[0]["source"] as? String == "disappearance")
            #expect(harness.posted("discard").isEmpty)
        }
    }

    /// What made the test above wait 25 s in a full run: in a hidden document `check` neither completes nor expires an attempt,
    /// and the first check once the document is shown again does. WebKit hides the document of a window off screen at once.
    @Test(.boundedWebViews) func aHiddenDocumentKeepsItsAttemptUntilItIsShownAgain() async throws {
        try await withHarness(.webKit, Self.verifyingPage) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            let window = try #require(harness.page.window)
            window.orderOut(nil)
            try #require(await waitUntil { (try? await harness.page.evaluateJavaScript("document.visibilityState")) as? String == "hidden" })
            _ = try await harness.page.evaluateJavaScript("document.getElementById('app').innerHTML = '<p>Welcome</p>'; true;")
            try await harness.age(130_000)
            try await harness.run("globalThis.__wsurfAutofillSave.check();")
            try await harness.settle()
            #expect(harness.posted("complete").isEmpty)
            #expect(harness.posted("discard").isEmpty)

            window.orderFrontRegardless()
            try await harness.check()
            try #require(await waitUntil { harness.posted("discard").count == 1 })
            #expect(harness.posted("complete").isEmpty)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func attemptsWithoutAVerificationStepStillExpireAfterTwoMinutes(engine: BrowserEngine) async throws {
        try await withHarness(engine, Self.verifyingPage) { harness in
            try await typeLogin(harness)
            try await harness.hook("click", "go")
            try #require(await waitUntil { harness.staged.count == 1 })
            try await harness.age(130_000)
            try await harness.check()
            try #require(await waitUntil { harness.posted("discard").count == 1 })
            #expect(harness.posted("complete").isEmpty)
        }
    }

    // MARK: Test hooks exist only in a test process

    @Test func theShippedScriptHasNoTestHooksAndLoadsOnlyOverHTTPS() throws {
        let shipped = AutofillSaveScript.client(testHooks: false)
        #expect(!shipped.contains("__test"))
        #expect(!shipped.contains("http:"))
        #expect(shipped.contains("['https:']"))
        #expect(AutofillSaveScript.client(testHooks: true).contains("__test"))
        // Nothing in the app asks for the hooks: the only caller that does not say `false` is the test-process default.
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root.appending(path: "WSurf"), includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("testHooks: true"), "\(file.lastPathComponent)")
            if text.contains("testHooks: AppDatabase.isRunningTests") {
                // The input-history script keeps the same test-process default; its own tests check it ships without hooks.
                #expect(["AutofillSaveScript.swift", "InputHistoryScript.swift"].contains(file.lastPathComponent), "\(file.lastPathComponent)")
            }
        }
    }

    private func shippedScriptState(url: URL?, baseURL: URL?) async throws -> String {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: AutofillFormScript.source + AutofillSaveScript.client(testHooks: false),
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: AutofillPage.world
        ))
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration), context: context)
        if let url {
            page.load(URLRequest(url: url))
        } else {
            page.loadHTMLString("<!doctype html><form><input></form>", baseURL: baseURL)
        }
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(20)))
        let state = try await page.callAsyncJavaScript(
            "return [typeof globalThis.__wsurfAutofillSave, typeof globalThis.__wsurfAutofillSave?.__test].join();",
            arguments: [:], in: nil, contentWorld: AutofillPage.world
        )
        await page.close()
        await context.endPrivateSession()
        return try #require(state as? String)
    }

    /// Chromium cannot load an HTTPS document from a fixture here, so the shipped scheme rule is read through WebKit.
    @Test(.boundedWebViews) func shippedScriptInstallsOnHTTPSWithoutHooks() async throws {
        #expect(try await shippedScriptState(url: nil, baseURL: URL(string: "https://login.example/")) == "object,undefined")
    }

    @Test(.boundedWebViews) func shippedScriptRefusesPlainHTTP() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><form><input></form>")])
        defer { withExtendedLifetime(server) {} }
        #expect(try await shippedScriptState(url: server.url(), baseURL: nil) == "undefined,undefined")
    }
}
